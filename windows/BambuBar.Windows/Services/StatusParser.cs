using System.Globalization;
using System.Text;
using System.Text.Json;
using BambuBar.Models;

namespace BambuBar.Services;

/// <summary>Parses Bambu MQTT telemetry JSON, ported 1:1 from the macOS BambuStatusParser.</summary>
public static class StatusParser
{
    public static PrinterTelemetry? Telemetry(byte[] data, PrinterTelemetry? previous = null)
    {
        JsonElement root;
        try
        {
            using var doc = JsonDocument.Parse(data);
            root = doc.RootElement.Clone();
        }
        catch { return null; }

        if (root.ValueKind != JsonValueKind.Object) return null;
        JsonElement report;
        if (root.TryGetProperty("print", out var p)) report = p;
        else if (root.TryGetProperty("pushing", out var pu)) report = pu;
        else return null;
        if (report.ValueKind != JsonValueKind.Object) return null;

        var result = previous?.Clone() ?? new PrinterTelemetry();

        if (Str(report, "gcode_state") is { } state) result.State = MapState(state);
        if (Int(report, "mc_percent") is { } percent) result.Progress = Math.Min(Math.Max(percent, 0), 100);
        if (Int(report, "mc_remaining_time") is { } rem) result.RemainingMinutes = rem;
        if (Num(report, "nozzle_temper") is { } nt) result.NozzleTemperature = nt;
        if (Num(report, "nozzle_target_temper") is { } ntt) result.NozzleTargetTemperature = ntt;
        if (Num(report, "bed_temper") is { } bt) result.BedTemperature = bt;
        if (Num(report, "bed_target_temper") is { } btt) result.BedTargetTemperature = btt;
        if (Num(report, "chamber_temper") is { } ct) result.ChamberTemperature = ct;
        if (Int(report, "layer_num") is { } ln) result.CurrentLayer = ln;
        if (Int(report, "total_layer_num") is { } tln) result.TotalLayers = tln;

        if (report.TryGetProperty("stage", out var stage) && stage.ValueKind == JsonValueKind.Object && Int(stage, "_id") is { } sid)
            result.CurrentStage = sid;
        else if (Int(report, "stg_cur") is { } stg)
            result.CurrentStage = stg;

        if ((Str(report, "print_type")?.ToLowerInvariant() == "idle") && result.CurrentStage == 0)
            result.CurrentStage = 255;

        if (Str(report, "subtask_name") is { Length: > 0 } job) result.JobName = DisplayName(job);
        if (UInt64Value(report, "print_error") is { } err) result.ErrorCode = err;

        if (report.TryGetProperty("hms", out var hms) && hms.ValueKind == JsonValueKind.Array)
        {
            var codes = new List<string>();
            foreach (var item in hms.EnumerateArray())
                if (HmsCode(item) is { } code) codes.Add(code);
            result.HmsCodes = codes;
        }

        if (report.TryGetProperty("ams", out var ams) && ams.ValueKind == JsonValueKind.Object)
        {
            var (slots, humidity, temperature) = ParseAms(ams);
            // Partial status updates during a print often carry only tray_now without the tray
            // list; keep the last known slots then instead of blanking the AMS display.
            if (slots.Count > 0) result.AmsSlots = slots;
            if (humidity is { }) result.AmsHumidity = humidity;
            if (temperature is { }) result.AmsTemperature = temperature;
        }

        if (result.ErrorCode != 0) result.State = PrinterState.Error;
        result.LastUpdated = DateTime.Now;
        return result;
    }

    public static PrinterState MapState(string raw) => raw.ToUpperInvariant() switch
    {
        "RUNNING" or "PREPARE" => PrinterState.Printing,
        "PAUSE" or "PAUSED" => PrinterState.Paused,
        "FINISH" or "FINISHED" => PrinterState.Finished,
        "FAILED" or "ERROR" => PrinterState.Error,
        "IDLE" => PrinterState.Idle,
        _ => PrinterState.Idle
    };

    private static string DisplayName(string raw)
    {
        string value = Uri.UnescapeDataString(raw);
        if (value.Contains('Ã') || value.Contains('Å') || value.Contains('Ä'))
        {
            try
            {
                var bytes = Encoding.GetEncoding(1252).GetBytes(value);
                value = Encoding.UTF8.GetString(bytes);
            }
            catch { /* keep original */ }
        }
        return value.Normalize(NormalizationForm.FormC);
    }

    private static (List<AmsSlot> Slots, int? Humidity, double? Temperature) ParseAms(JsonElement ams)
    {
        string activeRaw = Str(ams, "tray_now") ?? Int(ams, "tray_now")?.ToString() ?? "";
        var slots = new List<AmsSlot>();
        int? humidity = null;
        double? temperature = null;

        if (ams.TryGetProperty("ams", out var units) && units.ValueKind == JsonValueKind.Array)
        {
            int unitIndex = 0;
            foreach (var unit in units.EnumerateArray())
            {
                humidity ??= Int(unit, "humidity_raw") ?? Int(unit, "humidity");
                temperature ??= Num(unit, "temp");
                string unitId = Str(unit, "id") ?? unitIndex.ToString();
                string unitLetter = ((char)(65 + Math.Min(unitIndex, 25))).ToString();
                var trays = unit.TryGetProperty("tray", out var t) && t.ValueKind == JsonValueKind.Array
                    ? t.EnumerateArray().ToList()
                    : new List<JsonElement>();
                // A single-spool AMS reports itself as unit 128; a regular AMS owns four fixed positions.
                int slotCount = unitId == "128" ? 1 : 4;
                for (int trayIndex = 0; trayIndex < slotCount; trayIndex++)
                {
                    JsonElement tray = trayIndex < trays.Count ? trays[trayIndex] : default;
                    bool hasTray = trayIndex < trays.Count;
                    string trayId = (hasTray ? (Str(tray, "id") ?? Int(tray, "id")?.ToString()) : null) ?? trayIndex.ToString();
                    string material = (hasTray ? (Str(tray, "tray_type") ?? Str(tray, "tray_sub_brands")) : null) ?? "";
                    string color = material.Length == 0 ? "8E8E93FF" : ((hasTray ? Str(tray, "tray_color") : null) ?? "8E8E93FF");
                    int globalIndex = unitIndex * 4 + trayIndex;
                    bool isActive = activeRaw == globalIndex.ToString() || activeRaw == $"{unitId}{trayId}";
                    slots.Add(new AmsSlot
                    {
                        Id = $"ams-{unitId}-{trayId}",
                        Label = $"{unitLetter}{trayIndex + 1}",
                        Material = material.Length == 0 ? "—" : material,
                        ColorHex = color,
                        RemainingPercent = material.Length == 0 ? null : (hasTray ? Int(tray, "remain") : null),
                        IsActive = isActive,
                        IsExternal = false
                    });
                }
                unitIndex++;
            }
        }

        if (ams.TryGetProperty("vt_tray", out var external) && external.ValueKind == JsonValueKind.Object)
        {
            string material = Str(external, "tray_type") ?? Str(external, "tray_sub_brands") ?? "";
            if (material.Length > 0)
            {
                string trayId = Str(external, "id") ?? "254";
                slots.Add(new AmsSlot
                {
                    Id = $"external-{trayId}",
                    Label = "EXT",
                    Material = material,
                    ColorHex = Str(external, "tray_color") ?? "E8E8E8FF",
                    RemainingPercent = Int(external, "remain"),
                    IsActive = activeRaw == trayId || activeRaw == "254" || activeRaw == "255",
                    IsExternal = true
                });
            }
        }

        return (slots, humidity, temperature);
    }

    private static string? HmsCode(JsonElement item)
    {
        if (UInt64Value(item, "code") is not { } code) return null;
        ulong attr = UInt64Value(item, "attr") ?? 0;
        if (attr == 0 && Str(item, "ecode") is { Length: > 0 } raw)
            return raw.Replace("_", "").ToUpperInvariant();
        return $"{attr:X8}{code:X8}";
    }

    private static string? Str(JsonElement obj, string key)
        => obj.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static double? Num(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return d;
        if (v.ValueKind == JsonValueKind.String && double.TryParse(v.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var ds)) return ds;
        return null;
    }

    private static int? Int(JsonElement obj, string key)
    {
        var n = Num(obj, key);
        return n.HasValue ? (int)n.Value : null;
    }

    private static ulong? UInt64Value(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number)
        {
            if (v.TryGetUInt64(out var u)) return u;
            if (v.TryGetDouble(out var d)) return (ulong)d;
        }
        if (v.ValueKind == JsonValueKind.String)
        {
            string s = v.GetString() ?? "";
            if (ulong.TryParse(s, out var dec)) return dec;
            string hex = s.Replace("0x", "");
            if (ulong.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var h)) return h;
        }
        return null;
    }
}
