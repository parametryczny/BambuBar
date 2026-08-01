import Foundation

enum PrinterState: String, Codable, Sendable {
    case idle
    case printing
    case paused
    case finished
    case error
    case offline

    var label: String {
        switch self {
        case .idle: "Gotowa"
        case .printing: "Drukowanie"
        case .paused: "Wstrzymana"
        case .finished: "Zakończono"
        case .error: "Błąd"
        case .offline: "Offline"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "checkmark.circle.fill"
        case .printing: "printer.fill"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.seal.fill"
        case .error: "exclamationmark.triangle.fill"
        case .offline: "wifi.slash"
        }
    }
}

struct PrinterTelemetry: Equatable, Sendable {
    var state: PrinterState = .offline
    var progress: Int = 0
    var remainingMinutes: Int?
    var nozzleTemperature: Double?
    var nozzleTargetTemperature: Double?
    var bedTemperature: Double?
    var bedTargetTemperature: Double?
    var chamberTemperature: Double?
    var currentLayer: Int?
    var totalLayers: Int?
    var currentStage: Int?
    var jobName: String?
    var errorCode: UInt64 = 0
    var hmsCodes: [String] = []
    var amsSlots: [AMSSlot] = []
    var amsHumidity: Int?
    var amsTemperature: Double?
    var lastUpdated: Date?
}

struct AMSSlot: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let material: String
    let colorHex: String
    let remainingPercent: Int?
    let isActive: Bool
    let isExternal: Bool
}

enum PrinterKind: String, Codable, Sendable {
    case bambu
    case klipper
}

struct SavedPrinter: Codable, Identifiable, Hashable, Sendable {
    var id: String { serial }
    let serial: String
    var name: String
    var model: String
    var host: String
    var kind: PrinterKind
    /// Moonraker port for Klipper printers (default 7125). Unused for Bambu.
    var port: Int?
    /// Optional Moonraker API key for Klipper printers.
    var apiKey: String?

    init(serial: String, name: String, model: String = "Bambu Lab", host: String,
         kind: PrinterKind = .bambu, port: Int? = nil, apiKey: String? = nil) {
        self.serial = serial
        self.name = name
        self.model = model
        self.host = host
        self.kind = kind
        self.port = port
        self.apiKey = apiKey
    }

    enum CodingKeys: String, CodingKey { case serial, name, model, host, kind, port, apiKey }

    // Custom decoding so printers saved before the Klipper fields existed still load as Bambu.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serial = try container.decode(String.self, forKey: .serial)
        name = try container.decode(String.self, forKey: .name)
        model = (try? container.decode(String.self, forKey: .model)) ?? "Bambu Lab"
        host = try container.decode(String.self, forKey: .host)
        kind = (try? container.decode(PrinterKind.self, forKey: .kind)) ?? .bambu
        port = try? container.decodeIfPresent(Int.self, forKey: .port)
        apiKey = try? container.decodeIfPresent(String.self, forKey: .apiKey)
    }
}

struct DiscoveredPrinter: Identifiable, Hashable, Sendable {
    var id: String { serial }
    let serial: String
    let name: String
    let model: String
    let host: String
}
