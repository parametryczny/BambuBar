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

/// The A1 family and the P1 family have no chamber temperature sensor and report a placeholder
/// that should not be shown as a chamber reading. Every other model (X1, X2, P2, H2D…) has one,
/// so default to showing it. Detected from the serial-number model prefix.
func printerHasChamberSensor(serial: String) -> Bool {
    let prefix = String(serial.prefix(3)).uppercased()
    // 030 = A1 mini, 039 = A1, 01S/01P = P1S/P1P.
    return !["030", "039", "01S", "01P"].contains(prefix)
}
