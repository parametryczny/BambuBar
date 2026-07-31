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

struct SavedPrinter: Codable, Identifiable, Hashable, Sendable {
    var id: String { serial }
    let serial: String
    var name: String
    var model: String
    var host: String

    init(serial: String, name: String, model: String = "Bambu Lab", host: String) {
        self.serial = serial
        self.name = name
        self.model = model
        self.host = host
    }
}

struct DiscoveredPrinter: Identifiable, Hashable, Sendable {
    var id: String { serial }
    let serial: String
    let name: String
    let model: String
    let host: String
}
