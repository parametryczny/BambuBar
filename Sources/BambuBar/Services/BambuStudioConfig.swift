import Foundation

enum BambuStudioConfig {
    static func accessCodes() throws -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BambuStudio/BambuStudio.conf")
        guard let data = try? Data(contentsOf: url) else {
            throw BambuStudioConfigError("Nie znaleziono konfiguracji Bambu Studio.")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BambuStudioConfigError("Nie udało się odczytać konfiguracji Bambu Studio.")
        }
        let standard = stringDictionary(root["access_code"])
        let user = stringDictionary(root["user_access_code"])
        let result = standard.merging(user) { _, preferred in preferred }
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
        guard !result.isEmpty else {
            throw BambuStudioConfigError("Bambu Studio nie ma zapisanych kodów drukarek.")
        }
        return result
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, item in
            if let code = item.value as? String { result[item.key] = code }
        }
    }
}

struct BambuStudioConfigError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
