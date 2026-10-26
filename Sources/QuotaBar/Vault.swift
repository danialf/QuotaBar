import AppKit
import CryptoKit
import Foundation
import LocalAuthentication

/// Every secret QuotaBar keeps (API keys, admin keys, the Z.ai key), readable only after Touch ID.
///
/// One P-256 key lives in the Secure Enclave with a user-presence access control. Each secret
/// is sealed to its public key (ephemeral ECDH → HKDF → AES-GCM), which needs no prompt. Opening
/// needs the enclave's private key, so it needs an authenticated LAContext.
///
/// The sealed blobs and the enclave key's handle are kept in a 0600 file rather than the login
/// Keychain: they are useless off this Mac's Secure Enclave, and Keychain ACLs pin the app's
/// code signature, so every rebuild of an ad-hoc signed app would ask for the login password.
enum Vault {
    private static let salt = Data("QuotaBar.vault.v1".utf8)

    enum VaultError: LocalizedError {
        case unavailable, missing, cancelled
        var errorDescription: String? {
            switch self {
            case .unavailable: "This Mac has no Secure Enclave"
            case .missing: "No key saved"
            case .cancelled: "Authentication cancelled"
            }
        }
    }

    // MARK: Storage

    private struct Store: Codable {
        var enclaveKey: Data?
        var items: [String: Data] = [:]
    }

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "QuotaBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appending(path: "vault.json")
    }()

    private static let lock = NSLock()

    private static func load() -> Store {
        guard let data = try? Data(contentsOf: fileURL) else { return Store() }
        return (try? JSONDecoder().decode(Store.self, from: data)) ?? Store()
    }

    private static func save(_ store: Store) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func has(_ name: String) -> Bool { lock.withLock { load().items[name] != nil } }

    static func remove(_ name: String) {
        lock.withLock { var s = load(); s.items[name] = nil; save(s) }
    }

    // MARK: Seal / open

    /// Never prompts: sealing only needs the enclave key's public half.
    static func seal(_ secret: String, as name: String) throws {
        guard SecureEnclave.isAvailable else { throw VaultError.unavailable }
        try lock.withLock {
            var store = load()
            let recipient = try enclavePublicKey(&store)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
            let box = try AES.GCM.seal(Data(secret.utf8), using: symmetric(shared, ephemeral.publicKey))
            store.items[name] = ephemeral.publicKey.rawRepresentation + box.combined!
            save(store)
        }
    }

    /// Shows Touch ID (password only as the fallback button) and returns a context that can
    /// open any number of secrets without asking again.
    @MainActor static func authenticate(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password…"
        // Menu-bar apps are never frontmost; the sheet needs us active to come up as Touch ID.
        NSApp.activate(ignoringOtherApps: true)
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        do {
            try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch let e as LAError where e.code == .userFallback {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw VaultError.cancelled
        }
        return context
    }

    static func open(_ name: String, context: LAContext) throws -> String {
        let store = lock.withLock { load() }
        guard let blob = store.items[name], blob.count > 64, let keyData = store.enclaveKey else { throw VaultError.missing }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: keyData, authenticationContext: context)
        let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: blob.prefix(64))
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: blob.dropFirst(64)), using: symmetric(shared, ephemeral))
        return String(decoding: plain, as: UTF8.self)
    }

    /// Prompts once, then returns the secret.
    @MainActor static func open(_ name: String, reason: String) async throws -> String {
        guard has(name) else { throw VaultError.missing }
        return try open(name, context: try await authenticate(reason: reason))
    }

    /// Copies to the clipboard and clears it after `seconds`, unless something else was copied since.
    @MainActor static func copyToClipboard(_ secret: String, clearAfter seconds: Double = 90) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(secret, forType: .string)
        let stamp = pb.changeCount
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if pb.changeCount == stamp { pb.clearContents() }
        }
    }

    private static func symmetric(_ shared: SharedSecret, _ ephemeral: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: ephemeral.rawRepresentation, outputByteCount: 32)
    }

    private static func enclavePublicKey(_ store: inout Store) throws -> P256.KeyAgreement.PublicKey {
        if let data = store.enclaveKey, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data) {
            return key.publicKey
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], &error) else {
            throw error!.takeRetainedValue() as Error
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        store.enclaveKey = key.dataRepresentation
        return key.publicKey
    }

    // MARK: Migration

    /// One-time move of secrets saved by earlier builds in the login Keychain. Reading those
    /// may show one last Keychain password prompt; afterwards the Keychain is never touched.
    static func migrateFromKeychain(names: [String]) {
        let flag = "vault.migratedFromKeychain"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        for name in names {
            guard let value = Secrets.get(name) else { continue }
            try? seal(value, as: name)
            Secrets.set(name, nil)
        }
        // Earlier builds sealed API keys to an enclave key stored in the Keychain; those
        // blobs can't move without a prompt, so they are dropped and must be pasted again.
        for legacy in ["vault.enclaveKey"] { Secrets.set(legacy, nil) }
    }
}

/// A display hint that identifies a key without revealing it: "sk-ant-api03-R2D…igAA".
enum KeyHint {
    static func make(_ key: String) -> String {
        guard key.count > 20 else { return "••••" }
        return "\(key.prefix(16))…\(key.suffix(4))"
    }
}
