import Foundation

enum BambuStatusParser {
    static func telemetry(from data: Data, previous: PrinterTelemetry = .init()) -> PrinterTelemetry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = (root["print"] ?? root["pushing"]) as? [String: Any] else { return nil }

        var result = previous
        if let state = string(report["gcode_state"]) { result.state = mapState(state) }
        if let value = integer(report["mc_percent"]) { result.progress = min(max(value, 0), 100) }
        if let value = integer(report["mc_remaining_time"]) { result.remainingMinutes = value }
        if let value = number(report["nozzle_temper"]) { result.nozzleTemperature = value }
        if let value = number(report["nozzle_target_temper"]) { result.nozzleTargetTemperature = value }
        if let value = number(report["bed_temper"]) { result.bedTemperature = value }
        if let value = number(report["bed_target_temper"]) { result.bedTargetTemperature = value }
        if let value = number(report["chamber_temper"]) { result.chamberTemperature = value }
        if let value = integer(report["layer_num"]) { result.currentLayer = value }
        if let value = integer(report["total_layer_num"]) { result.totalLayers = value }
        if let stage = report["stage"] as? [String: Any], let value = integer(stage["_id"]) {
            result.currentStage = value
        } else if let value = integer(report["stg_cur"]) {
            result.currentStage = value
        }
        if string(report["print_type"])?.lowercased() == "idle", result.currentStage == 0 {
            result.currentStage = 255
        }
        if let value = string(report["subtask_name"]), !value.isEmpty { result.jobName = displayName(value) }
        if let value = uint64(report["print_error"]) { result.errorCode = value }
        if let hms = report["hms"] as? [[String: Any]] {
            result.hmsCodes = hms.compactMap(hmsCode)
        }
        if let ams = report["ams"] as? [String: Any] {
            let amsData = parseAMS(ams)
            // Partial status updates during a print often carry only `tray_now` without the
            // tray list, which would otherwise blank the AMS display until the next full
            // report. Keep the last known slots when the update has none.
            if !amsData.slots.isEmpty { result.amsSlots = amsData.slots }
            if let humidity = amsData.humidity { result.amsHumidity = humidity }
            if let temperature = amsData.temperature { result.amsTemperature = temperature }
        }
        if result.errorCode != 0 { result.state = .error }
        result.lastUpdated = Date()
        return result
    }

    static func mapState(_ raw: String) -> PrinterState {
        switch raw.uppercased() {
        case "RUNNING", "PREPARE": .printing
        case "PAUSE", "PAUSED": .paused
        case "FINISH", "FINISHED": .finished
        case "FAILED", "ERROR": .error
        case "IDLE": .idle
        default: .idle
        }
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func displayName(_ raw: String) -> String {
        var value = raw.removingPercentEncoding ?? raw
        if value.contains("Ã") || value.contains("Å") || value.contains("Ä") {
            if let bytes = value.data(using: .windowsCP1252),
               let repaired = String(data: bytes, encoding: .utf8) {
                value = repaired
            }
        }
        return value.precomposedStringWithCanonicalMapping
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String {
            if let decimal = UInt64(string) { return decimal }
            return UInt64(string.replacingOccurrences(of: "0x", with: ""), radix: 16)
        }
        return nil
    }

    private static func hmsCode(_ item: [String: Any]) -> String? {
        guard let code = uint64(item["code"]) else { return nil }
        let attr = uint64(item["attr"]) ?? 0
        if attr == 0, let raw = item["ecode"] as? String, !raw.isEmpty {
            return raw.replacingOccurrences(of: "_", with: "").uppercased()
        }
        return String(format: "%08llX%08llX", attr, code)
    }

    private static func parseAMS(_ ams: [String: Any]) -> (slots: [AMSSlot], humidity: Int?, temperature: Double?) {
        let activeRaw = string(ams["tray_now"]) ?? integer(ams["tray_now"]).map(String.init) ?? ""
        var slots: [AMSSlot] = []
        var humidity: Int?
        var temperature: Double?

        if let units = ams["ams"] as? [[String: Any]] {
            for (unitIndex, unit) in units.enumerated() {
                if humidity == nil { humidity = integer(unit["humidity_raw"]) ?? integer(unit["humidity"]) }
                if temperature == nil { temperature = number(unit["temp"]) }
                let unitID = string(unit["id"]) ?? String(unitIndex)
                let unitLetter = String(UnicodeScalar(65 + min(unitIndex, 25))!)
                let trays = unit["tray"] as? [[String: Any]] ?? []
                // A single-spool AMS identifies itself as unit 128. A regular
                // AMS owns four fixed positions, including currently empty ones.
                let slotCount = unitID == "128" ? 1 : 4
                for trayIndex in 0..<slotCount {
                    let tray = trays.indices.contains(trayIndex) ? trays[trayIndex] : [:]
                    let trayID = string(tray["id"]) ?? integer(tray["id"]).map(String.init) ?? String(trayIndex)
                    let material = string(tray["tray_type"]) ?? string(tray["tray_sub_brands"]) ?? ""
                    let color = material.isEmpty ? "8E8E93FF" : (string(tray["tray_color"]) ?? "8E8E93FF")
                    let globalIndex = unitIndex * 4 + trayIndex
                    let isActive = activeRaw == String(globalIndex) || activeRaw == "\(unitID)\(trayID)"
                    slots.append(AMSSlot(
                        id: "ams-\(unitID)-\(trayID)",
                        label: "\(unitLetter)\(trayIndex + 1)",
                        material: material.isEmpty ? "—" : material,
                        colorHex: color,
                        remainingPercent: material.isEmpty ? nil : integer(tray["remain"]),
                        isActive: isActive,
                        isExternal: false
                    ))
                }
            }
        }

        if let external = ams["vt_tray"] as? [String: Any] {
            let material = string(external["tray_type"]) ?? string(external["tray_sub_brands"]) ?? ""
            if !material.isEmpty {
                let trayID = string(external["id"]) ?? "254"
                slots.append(AMSSlot(
                    id: "external-\(trayID)",
                    label: "EXT",
                    material: material,
                    colorHex: string(external["tray_color"]) ?? "E8E8E8FF",
                    remainingPercent: integer(external["remain"]),
                    isActive: activeRaw == trayID || activeRaw == "254" || activeRaw == "255",
                    isExternal: true
                ))
            }
        }
        return (slots, humidity, temperature)
    }
}
