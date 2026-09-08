import Foundation
import Security

enum KeychainHelper {
    enum KeychainError: LocalizedError, Equatable {
        case security(OSStatus)
        case invalidData
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .security(let status):
                if status == errSecMissingEntitlement {
                    return "Secure storage is unavailable because this build is not signed correctly."
                }
                return "Could not access secure storage (\(status))."
            case .invalidData:
                return "Secure storage contains invalid data."
            case .verificationFailed:
                return "The API key could not be verified after saving."
            }
        }
    }

    private static let service = Bundle.main.bundleIdentifier ?? "com.textora.app"
    private static let account = "apiTokens"

    private static var cache: [String: String] = [:]
    private static var cacheLoaded = false

    static let openAIKeyAccount = "openaiKey"
    static let geminiKeyAccount = "geminiKey"
    static let claudeKeyAccount = "claudeKey"
    static let customTokenAccount = "customToken"

    // MARK: - Public API

    @discardableResult
    static func save(key: String, value: String) -> Result<Void, KeychainError> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        func updated(_ values: [String: String]) -> [String: String] {
            var next = values
            if trimmed.isEmpty { next.removeValue(forKey: key) } else { next[key] = trimmed }
            return next
        }

        let loaded = loadAll()
        guard case .success(let current) = loaded else {
            if case .failure(let error) = loaded { return .failure(error) }
            return .failure(.invalidData)
        }
        let currentValue = current[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard currentValue != trimmed else { return .success(()) }
        return persist(updated(current))
    }

    static func read(key: String) -> String? {
        try? load(key: key).get()
    }

    static func load(key: String) -> Result<String?, KeychainError> {
        loadAll().map { values in
            let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }

    @discardableResult
    static func delete(key: String) -> Result<Void, KeychainError> {
        save(key: key, value: "")
    }

    @discardableResult
    static func warmUpCache() -> Result<Void, KeychainError> {
        loadAll().map { _ in () }
    }

    // MARK: - Migration (one-time: old keychain / UserDefaults / file -> system Keychain)

    @discardableResult
    static func migrateIfNeeded() -> Result<Void, KeychainError> {
        let migrated = UserDefaults.standard.bool(forKey: "tokens.dp.migrated")
        guard !migrated else { return warmUpCache() }

        let modern = loadAll()
        guard case .success(var migratedValues) = modern else {
            if case .failure(let error) = modern { return .failure(error) }
            return .failure(.invalidData)
        }
        var legacyDefaultsKeys: [String] = []
        var shouldRemoveLegacyFile = false

        // Legacy keychain services are not probed automatically. Their ACL can
        // show password dialogs for an older app identity during every launch.

        // 1. Very old UserDefaults storage for the current bundle.
        for key in [openAIKeyAccount, geminiKeyAccount, claudeKeyAccount, customTokenAccount] {
            if let val = UserDefaults.standard.string(forKey: key), !val.isEmpty {
                if migratedValues[key]?.isEmpty != false { migratedValues[key] = val }
                legacyDefaultsKeys.append(key)
            }
        }

        // 2. Intermediate file-based storage (tokens.json).
        #if DEBUG
        if let fileTokens = readFromFile() {
            for (k, v) in fileTokens where !v.isEmpty {
                if migratedValues[k]?.isEmpty != false { migratedValues[k] = v }
            }
            shouldRemoveLegacyFile = true
        }
        #else
        removeTokensFile()
        #endif

        if !migratedValues.isEmpty {
            if case .failure(let error) = persist(migratedValues) { return .failure(error) }
        }

        #if DEBUG
        if shouldRemoveLegacyFile { removeTokensFile() }
        #endif
        legacyDefaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(true, forKey: "tokens.dp.migrated")
        UserDefaults.standard.set(true, forKey: "tokens.file.migrated")
        UserDefaults.standard.set(true, forKey: "keychain.migrated.v2")
        UserDefaults.standard.set(true, forKey: "keychain.migrated")
        return .success(())
    }

    // MARK: - macOS system Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func loadAll() -> Result<[String: String], KeychainError> {
        if cacheLoaded { return .success(cache) }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            cache = [:]
            cacheLoaded = true
            return .success([:])
        }
        guard status == errSecSuccess else { return .failure(.security(status)) }
        guard let data = item as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return .failure(.invalidData)
        }
        cache = dict
        cacheLoaded = true
        return .success(dict)
    }

    private static func persist(_ values: [String: String]) -> Result<Void, KeychainError> {
        let nonEmpty = values.filter { !$0.value.isEmpty }
        if nonEmpty.isEmpty {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                return .failure(.security(status))
            }
            cache = [:]
            cacheLoaded = true
            return .success(())
        }
        guard let data = try? JSONEncoder().encode(nonEmpty) else { return .failure(.invalidData) }
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        let status: OSStatus
        if updateStatus == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        } else {
            status = updateStatus
        }
        guard status == errSecSuccess else { return .failure(.security(status)) }

        cacheLoaded = false
        guard case .success(let verified) = loadAll(), verified == nonEmpty else {
            cacheLoaded = false
            return .failure(.verificationFailed)
        }
        removeTokensFile()
        return .success(())
    }

    // MARK: - File-based storage (intermediate format, for migration only)

    private static var tokensFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent(service, isDirectory: true)
            .appendingPathComponent("tokens.json")
    }

    private static func readFromFile() -> [String: String]? {
        guard let data = try? Data(contentsOf: tokensFileURL) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func removeTokensFile() {
        try? FileManager.default.removeItem(at: tokensFileURL)
    }
}
