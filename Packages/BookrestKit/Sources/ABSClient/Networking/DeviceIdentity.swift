import Foundation

/// Identifies this install to the server. The device id must be stable across
/// launches — Audiobookshelf keys open playback sessions on it, and a changing id
/// leaves orphaned sessions behind on every cold start.
public enum DeviceIdentity {
    private static let deviceIdKey = "com.bookrest.deviceId"

    public static let deviceId: String = {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIdKey)
        return generated
    }()

    public static let clientName = "Bookrest"

    public static let clientVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }()

    public static let manufacturer = "Apple"

    /// Read from `uname` rather than `UIDevice`, which is main-actor isolated and so
    /// can't initialise a global. This also reports the precise hardware identifier
    /// ("iPhone16,2"), which is more useful in the server's device list.
    public static let model: String = {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        if !identifier.isEmpty { return identifier }
        #if os(macOS)
        return "Mac"
        #else
        return "iOS Device"
        #endif
    }()

    public static let osVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }()

    public static let userAgent: String = "\(clientName)/\(clientVersion) (\(model); \(osVersion))"

    public static var playRequestDeviceInfo: PlayRequest.DeviceInfo {
        PlayRequest.DeviceInfo(
            deviceId: deviceId,
            clientName: clientName,
            clientVersion: clientVersion,
            manufacturer: manufacturer,
            model: model,
            sdkVersion: osVersion
        )
    }

    /// Formats AVFoundation can decode without the server transcoding. Sent on every
    /// play request so the server picks direct play whenever the source allows it.
    public static let supportedMimeTypes: [String] = [
        "audio/flac",
        "audio/mpeg",
        "audio/mp4",
        "audio/aac",
        "audio/x-m4a",
        "audio/x-m4b",
        "audio/m4b",
        "audio/mp3",
        "audio/wav",
        "audio/x-wav",
        "audio/aiff",
        "audio/x-aiff",
        "audio/opus",
        "audio/ogg",
        "audio/webm",
    ]
}
