import Foundation

enum NotificationService {
    static func post(title: String, body: String, subtitle: String? = nil) {
        let safeTitle = escaped(title)
        let safeBody = escaped(body)
        let subtitleClause = subtitle.map { " subtitle \"\(escaped($0))\"" } ?? ""
        let script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\"\(subtitleClause)"
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
