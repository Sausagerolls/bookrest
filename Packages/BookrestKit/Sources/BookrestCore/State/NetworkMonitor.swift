import Foundation
import Network
import Observation

/// Tracks connectivity so the app can fall back to downloads, pause retry storms,
/// and flush queued progress the moment the network returns.
@MainActor
@Observable
public final class NetworkMonitor {
    public private(set) var isConnected: Bool = true
    public private(set) var isConstrained: Bool = false
    public private(set) var isExpensive: Bool = false

    /// Called on the transition from offline to online, not on every path update.
    public var onReconnect: (@MainActor () -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bookrest.network-monitor")
    private var hasStarted = false

    public init() {}

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let constrained = path.isConstrained
            let expensive = path.isExpensive

            Task { @MainActor in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = connected
                self.isConstrained = constrained
                self.isExpensive = expensive
                if !wasConnected && connected { self.onReconnect?() }
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
        hasStarted = false
    }
}
