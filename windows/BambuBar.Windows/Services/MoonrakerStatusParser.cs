using System.Globalization;
using System.IO;
using System.Text.Json;
using BambuBar.Models;

namespace BambuBar.Services;

/// <summary>Parses a Moonraker printer/objects/query response into PrinterTelemetry, including the
/// Happy Hare mmu object mapped to AMS slots. Mirrors the macOS MoonrakerStatusParser.</summary>
public static class MoonrakerStatusParser
{
    public static PrinterTelemetry? Telemetry(byte[] data, PrinterTelemetry? previous = null)
    {
        JsonElement root;
        try { using var doc = JsonDocument.Parse(data); root = doc.RootElement.Clone(); }
        catch { return null; }

        JsonElement result = root.TryGetProperty("result", out var r) ? r : root;
        if (!result.TryGetProperty("status", out var status) || status.ValueKind != JsonValueKind.Object) return null;

        var t = previous?.Clone() ?? new PrinterTelemetry();

        if (Obj(status, "print_stats", out var printStats))
        {
            if (Str(printStats, "state") is { } state) t.State = MapState(state);
            if (Str(printStats, "filename") is { Length: > 0 } file) t.JobName = Path.GetFileName(file);
            if (Obj(printStats, "info", out var info))
            {
                if (Int(info, "current_layer") is { } cl) t.CurrentLayer = cl;
                if (Int(info, "total_layer") is { } tl) t.TotalLayers = tl;
            }
        }

        double? progress = null;
        if (Obj(status, "display_status", out var ds)) progress = Num(ds, "progress");
        if (progress is null && Obj(status, "virtual_sdcard", out var vs)) progress = Num(vs, "progress");
        if (progress is { } p) t.Progress = Math.Clamp((int)Math.Round(p * 100), 0, 100);

        if (Obj(status, "print_stats", out var ps) && Num(ps, "print_duration") is { } duration && duration > 0
            && progress is { } pr && pr > 0.01)
        {
            t.RemainingMinutes = (int)Math.Round(duration * (1 - pr) / pr / 60);
        }

        if (Obj(status, "extruder", out var extruder))
        {
            if (Num(extruder, "temperature") is { } temp) t.NozzleTemperature = temp;
            if (Num(extruder, "target") is { } target) t.NozzleTargetTemperature = target;
        }
        if (Obj(status, "heater_bed", out var bed))
        {
            if (Num(bed, "temperature") is { } temp) t.BedTemperature = temp;
            if (Num(bed, "target") is { } target) t.BedTargetTemperature = target;
        }
        if (ChamberTemperature(status) is { } chamber) t.ChamberTemperature = chamber;

        if (Obj(status, "mmu", out var mmu))
        {
            var slots = ParseMmu(mmu);
            if (slots.Count > 0) t.AmsSlots = slots;
        }

        t.LastUpdated = DateTime.Now;
        return t;
    }

    public static PrinterState MapState(string raw) => raw.ToLowerInvariant() switch
    {
        "printing" => PrinterState.Printing,
        "paused" => PrinterState.Paused,
        "complete" or "completed" => PrinterState.Finished,
        "error" => PrinterState.Error,
        "cancelled" or "canceled" or "standby" => PrinterState.Idle,
        _ => PrinterState.Idle
    };

    private static double? ChamberTemperature(JsonElement status)
    {
        foreach (var prop in status.EnumerateObject())
        {
            if (!prop.Name.ToLowerInvariant().Contains("chamber")) continue;
            if ((prop.Name.StartsWith("temperature_sensor") || prop.Name.StartsWith("heater_generic"))
                && prop.Value.ValueKind == JsonValueKind.Object && Num(prop.Value, "temperature") is { } temp)
                return temp;
        }
        return null;
    }

    private static List<AmsSlot> ParseMmu(JsonElement mmu)
    {
        if (mmu.TryGetProperty("enabled", out var enabled) && enabled.ValueKind == JsonValueKind.False) return new();
        if (Int(mmu, "num_gates") is not { } count || count <= 0) return new();

        var materials = Arr(mmu, "gate_material");
        var colors = Arr(mmu, "gate_color");
        var statuses = Arr(mmu, "gate_status");
        int current = Int(mmu, "gate") ?? -1;

        var slots = new List<AmsSlot>();
        for (int i = 0; i < count; i++)
        {
            int gateStatus = i < statuses.Count ? (IntValue(statuses[i]) ?? -1) : -1;
            string rawMaterial = i < materials.Count ? (StringValue(materials[i]) ?? "") : "";
            string material = gateStatus == 0 || rawMaterial.Length == 0 ? "—" : rawMaterial;
            string color = AmsColor(i < colors.Count ? StringValue(colors[i]) : null);
            slots.Add(new AmsSlot
            {
                Id = $"mmu-{i}",
                Label = $"T{i}",
                Material = material,
                ColorHex = color,
                RemainingPercent = null,
                IsActive = i == current,
                IsExternal = false
            });
        }
        return slots;
    }

    private static string AmsColor(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return "8E8E93FF";
        var value = raw.StartsWith('#') ? raw[1..] : raw;
        if (value.Length == 6) return (value + "FF").ToUpperInvariant();
        if (value.Length == 8) return value.ToUpperInvariant();
        return "8E8E93FF";
    }

    private static bool Obj(JsonElement parent, string key, out JsonElement value)
    {
        if (parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(key, out value) && value.ValueKind == JsonValueKind.Object)
            return true;
        value = default;
        return false;
    }

    private static List<JsonElement> Arr(JsonElement parent, string key)
    {
        if (parent.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Array)
            return value.EnumerateArray().ToList();
        return new();
    }

    private static string? Str(JsonElement obj, string key)
        => obj.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static double? Num(JsonElement obj, string key)
        => obj.TryGetProperty(key, out var v) ? NumberValue(v) : null;

    private static int? Int(JsonElement obj, string key)
    {
        var n = Num(obj, key);
        return n.HasValue ? (int)n.Value : null;
    }

    private static double? NumberValue(JsonElement v)
    {
        if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return d;
        if (v.ValueKind == JsonValueKind.String && double.TryParse(v.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var ds)) return ds;
        return null;
    }

    private static string? StringValue(JsonElement v) => v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static int? IntValue(JsonElement v)
    {
        var n = NumberValue(v);
        return n.HasValue ? (int)n.Value : null;
    }
}
