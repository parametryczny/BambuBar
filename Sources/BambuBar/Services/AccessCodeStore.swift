import Foundation
#if KEYCHAIN_STORAGE
import Security
#endif

@MainActor
enum AccessCodeStore {
    #if KEYCHAIN_STORAGE
    static let modeName = "Keychain"
    static let usesKeychain = true
    private static let service = "pl.bambubar.printer-access-code.v2"

    static func save(accessCode: String, for serial: String) throws {
        let data = Data(accessCode.utf8)
        guard !data.isEmpty else { throw AccessCodeStoreError.invalidData }
        let query = baseQuery(for: serial)
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecSuccess, let existing = result as? Data, existing == data { return }

        if readStatus == errSecSuccess {
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else { throw AccessCodeStoreError.keychain("update", status) }
            return
        }
        guard readStatus == errSecItemNotFound else {
            throw AccessCodeStoreError.keychain("lookup", readStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccessCodeStoreError.keychain("add", status) }
    }

    static func accessCode(for serial: String) -> String? {
        try? readAccessCode(for: serial)
    }

    static func readAccessCode(for serial: String) throws -> String {
        var query = baseQuery(for: serial)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw AccessCodeStoreError.missing }
            throw AccessCodeStoreError.keychain("read", status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AccessCodeStoreError.invalidData
        }
        return value
    }

    static func delete(for serial: String) {
        SecItemDelete(baseQuery(for: serial) as CFDictionary)
    }

    private static func baseQuery(for serial: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial
        ]
    }
    #else
    static let modeName = "Local"
    static let usesKeychain = false
    private static let defaults = BambuDefaults.shared
    private static let storageKey = "printer-access-codes-local-v1"

    static func save(accessCode: String, for serial: String) throws {
        var values = storedValues()
        guard values[serial] != accessCode else { return }
        values[serial] = accessCode
        defaults.set(values, forKey: storageKey)
    }

    static func accessCode(for serial: String) -> String? {
        storedValues()[serial]
    }

    static func readAccessCode(for serial: String) throws -> String {
        guard let value = accessCode(for: serial), !value.isEmpty else {
            throw AccessCodeStoreError.missing
        }
        return value
    }

    static func delete(for serial: String) {
        var values = storedValues()
        values.removeValue(forKey: serial)
        defaults.set(values, forKey: storageKey)
    }

    private static func storedValues() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
    #endif
}

enum AccessCodeStoreError: LocalizedError {
    case missing
    case invalidData
    #if KEYCHAIN_STORAGE
    case keychain(String, OSStatus)
    #endif

    var errorDescription: String? {
        switch self {
        case .missing:
            "Brak zapisanego kodu dostępu. Użyj importu z Bambu Studio albo edytuj drukarkę."
        case .invalidData:
            "Zapisanego kodu dostępu nie można odczytać."
        #if KEYCHAIN_STORAGE
        case .keychain(let operation, let status):
            "Keychain \(operation): \(SecCopyErrorMessageString(status, nil) as String? ?? "błąd") (\(status))"
        #endif
        }
    }
}
