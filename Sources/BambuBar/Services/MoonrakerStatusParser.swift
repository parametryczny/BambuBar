import Foundation

/// Parses a Moonraker `printer/objects/query` response into PrinterTelemetry, including the
/// Happy Hare `mmu` object mapped to AMS slots. Field names verified defensively; unknown or
/// missing values fall back to the previous telemetry.
enum MoonrakerStatusParser {
    static func telemetry(from data: Data, previous: PrinterTelemetry = .init()) -> PrinterTelemetry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let result = root["result"] as? [String: Any] ?? root
        guard let status = result["status"] as? [String: Any] else { return nil }

        var telemetry = previous

        if let printStats = status["print_stats"] as? [String: Any] {
            if let state = string(printStats["state"]) { telemetry.state = mapState(state) }
            if let name = string(printStats["filename"]), !name.isEmpty {
                telemetry.jobName = (name as NSString).lastPathComponent
            }
            if let info = printStats["info"] as? [String: Any] {
                if let current = integer(info["current_layer"]) { telemetry.currentLayer = current }
                if let total = integer(info["total_layer"]) { telemetry.totalLayers = total }
            }
        }

        // Progress: display_status is the slicer/M73 value; fall back to sd position.
        let progress = number((status["display_status"] as? [String: Any])?["progress"])
            ?? number((status["virtual_sdcard"] as? [String: Any])?["progress"])
        if let progress {
            telemetry.progress = min(max(Int((progress * 100).rounded()), 0), 100)
        }

        // ETA from elapsed print time and progress.
        if let printStats = status["print_stats"] as? [String: Any],
           let duration = number(printStats["print_duration"]), duration > 0,
           let progress, progress > 0.01 {
            let remainingSeconds = duration * (1 - progress) / progress
            telemetry.remainingMinutes = Int((remainingSeconds / 60).rounded())
        }

        if let extruder = status["extruder"] as? [String: Any] {
            if let temp = number(extruder["temperature"]) { telemetry.nozzleTemperature = temp }
            if let target = number(extruder["target"]) { telemetry.nozzleTargetTemperature = target }
        }
        if let bed = status["heater_bed"] as? [String: Any] {
            if let temp = number(bed["temperature"]) { telemetry.bedTemperature = temp }
            if let target = number(bed["target"]) { telemetry.bedTargetTemperature = target }
        }
        // Chamber: any temperature_sensor / heater_generic whose name mentions "chamber".
        if let chamber = chamberTemperature(in: status) { telemetry.chamberTemperature = chamber }

        if let mmu = status["mmu"] as? [String: Any] {
            let slots = parseMMU(mmu)
            if !slots.isEmpty { telemetry.amsSlots = slots }
        }

        telemetry.lastUpdated = Date()
        return telemetry
    }

    static func mapState(_ raw: String) -> PrinterState {
        switch raw.lowercased() {
        case "printing": .printing
        case "paused": .paused
        case "complete", "completed": .finished
        case "error": .error
        case "cancelled", "canceled", "standby": .idle
        default: .idle
        }
    }

    private static func chamberTemperature(in status: [String: Any]) -> Double? {
        for (key, value) in status where key.lowercased().contains("chamber") {
            if (key.hasPrefix("temperature_sensor") || key.hasPrefix("heater_generic")),
               let object = value as? [String: Any],
               let temp = number(object["temperature"]) {
                return temp
            }
        }
        return nil
    }

    private static func parseMMU(_ mmu: [String: Any]) -> [AMSSlot] {
        if let enabled = mmu["enabled"] as? Bool, !enabled { return [] }
        guard let count = integer(mmu["num_gates"]), count > 0 else { return [] }

        let materials = mmu["gate_material"] as? [Any] ?? []
        let colors = mmu["gate_color"] as? [Any] ?? []
        let statuses = mmu["gate_status"] as? [Any] ?? []
        let currentGate = integer(mmu["gate"]) ?? -1

        var slots: [AMSSlot] = []
        for index in 0..<count {
            let gateStatus = index < statuses.count ? (integer(statuses[index]) ?? -1) : -1
            let rawMaterial = index < materials.count ? (string(materials[index]) ?? "") : ""
            let material = gateStatus == 0 || rawMaterial.isEmpty ? "—" : rawMaterial
            let color = amsColor(index < colors.count ? string(colors[index]) : nil)
            slots.append(AMSSlot(
                id: "mmu-\(index)",
                label: "T\(index)",
                material: material,
                colorHex: color,
                remainingPercent: nil,
                isActive: index == currentGate,
                isExternal: false
            ))
        }
        return slots
    }

    /// Happy Hare gate colours are hex (6 chars) or a named colour; normalise to RRGGBBAA.
    private static func amsColor(_ raw: String?) -> String {
        guard var value = raw, !value.isEmpty else { return "8E8E93FF" }
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 6 { return (value + "FF").uppercased() }
        if value.count == 8 { return value.uppercased() }
        return "8E8E93FF"
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? { number(value).map(Int.init) }
}
