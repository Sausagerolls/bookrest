import Foundation

/// Where the signed-in connection is persisted.
///
/// Abstracted so tests can run without a Keychain. An unsigned test bundle has no
/// keychain entitlement and every access fails with `errSecMissingEntitlement`
/// (-34018), which would otherwise make the engine untestable on a simulator.
public protocol CredentialStorage: Sendable {
    func save(_ connection: ServerConnection) throws
    func load() -> ServerConnection?
    func clear()
}

/// Production storage: the login Keychain, readable after first unlock so background
/// downloads and CarPlay can authenticate on a locked device.
public struct KeychainCredentialStorage: CredentialStorage {
    private let keychain: Keychain
    private let account = "active-connection"

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    public func save(_ connection: ServerConnection) throws {
        try keychain.setValue(connection, for: account)
    }

    public func load() -> ServerConnection? {
        keychain.value(ServerConnection.self, for: account)
    }

    public func clear() {
        keychain.removeItem(for: account)
    }
}

/// Test storage. Holds the connection for the lifetime of the process only.
public final class InMemoryCredentialStorage: CredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: ServerConnection?

    public init() {}

    public func save(_ connection: ServerConnection) throws {
        lock.lock(); defer { lock.unlock() }
        self.connection = connection
    }

    public func load() -> ServerConnection? {
        lock.lock(); defer { lock.unlock() }
        return connection
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        connection = nil
    }
}
