import Foundation
import os

/// Atomically-persisted JSON document.
///
/// Writes go to a sibling temp file and are swapped in with `replaceItemAt`, so an
/// interrupted write (app killed mid-save, device powered off) can never leave a
/// truncated index behind — the previous good copy survives.
actor JSONFileStore<Value: Codable & Sendable> {
    private let url: URL
    private let makeDefault: @Sendable () -> Value
    private let logger = Logger(subsystem: "com.bookrest.app", category: "storage")

    private var cached: Value?
    private var saveTask: Task<Void, Never>?
    private let coalesceInterval: Duration

    init(url: URL, coalesceInterval: Duration = .milliseconds(400),
         makeDefault: @escaping @Sendable () -> Value) {
        self.url = url
        self.makeDefault = makeDefault
        self.coalesceInterval = coalesceInterval
    }

    func load() -> Value {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Value.self, from: data)
        else {
            let fallback = makeDefault()
            cached = fallback
            return fallback
        }
        cached = decoded
        return decoded
    }

    func update(_ transform: @Sendable (inout Value) -> Void) -> Value {
        var value = load()
        transform(&value)
        cached = value
        scheduleSave()
        return value
    }

    func replace(with value: Value) {
        cached = value
        scheduleSave()
    }

    /// Coalesces rapid updates — download progress ticks many times a second — into
    /// one disk write, while still guaranteeing a flush before the app suspends.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [coalesceInterval] in
            try? await Task.sleep(for: coalesceInterval)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    func flush() {
        guard let cached else { return }
        saveTask?.cancel()
        saveTask = nil
        do {
            StorageLocations.ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(cached)

            let temporaryURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp")
            try data.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            logger.error("Failed to persist \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
