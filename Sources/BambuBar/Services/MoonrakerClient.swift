import Foundation

/// Polls a Klipper printer's Moonraker API and reports status through MQTTClient.Event, so
/// PrinterStore treats Klipper and Bambu connections identically. REST polling keeps the first
/// version simple; a WebSocket subscription can replace the loop later.
final class MoonrakerClient: PrinterConnection, @unchecked Sendable {
    private let printer: SavedPrinter
    private let onEvent: @Sendable (MQTTClient.Event) -> Void
    private var task: Task<Void, Never>?
    private var telemetry = PrinterTelemetry()
    private var connectedReported = false
    private var disconnectReported = false

    init(printer: SavedPrinter, onEvent: @escaping @Sendable (MQTTClient.Event) -> Void) {
        self.printer = printer
        self.onEvent = onEvent
    }

    func start() {
        task = Task.detached(priority: .utility) { [weak self] in await self?.run() }
    }

    func stop() { task?.cancel() }

    private var baseURL: String { "http://\(printer.host):\(printer.port ?? 7125)" }

    private func run() async {
        guard let queryURL = await buildQueryURL() else {
            reportDisconnected("Nie znaleziono API Moonraker (port \(printer.port ?? 7125))")
            return
        }
        while !Task.isCancelled {
            do {
                let data = try await get(queryURL)
                if let updated = MoonrakerStatusParser.telemetry(from: data, previous: telemetry) {
                    telemetry = updated
                    if !connectedReported { connectedReported = true; onEvent(.connected) }
                    onEvent(.telemetry(updated))
                }
            } catch is CancellationError {
                return
            } catch {
                reportDisconnected(error.localizedDescription)
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Query only objects the printer actually exposes, so Moonraker doesn't reject the request,
    /// and pick up any chamber temperature sensor and the MMU object if present.
    private func buildQueryURL() async -> URL? {
        var wanted = ["print_stats", "virtual_sdcard", "display_status", "extruder", "heater_bed", "mmu"]
        if let listURL = URL(string: "\(baseURL)/printer/objects/list"),
           let data = try? await get(listURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let objects = (root["result"] as? [String: Any])?["objects"] as? [String] {
            let available = Set(objects)
            wanted = wanted.filter { available.contains($0) }
            for object in objects where object.lowercased().contains("chamber")
                && (object.hasPrefix("temperature_sensor") || object.hasPrefix("heater_generic")) {
                wanted.append(object)
            }
        }
        guard !wanted.isEmpty else { return nil }
        var components = URLComponents(string: "\(baseURL)/printer/objects/query")
        components?.queryItems = wanted.map { URLQueryItem(name: $0, value: nil) }
        return components?.url
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let key = printer.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func reportDisconnected(_ reason: String?) {
        guard !disconnectReported else { return }
        disconnectReported = true
        onEvent(.disconnected(reason))
    }
}
