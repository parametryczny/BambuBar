using System.Text.Json.Serialization;

namespace BambuBar.Models;

public enum PrinterState
{
    Idle,
    Printing,
    Paused,
    Finished,
    Error,
    Offline
}

public static class PrinterStateExtensions
{
    public static string Label(this PrinterState state, bool polish) => state switch
    {
        PrinterState.Idle => polish ? "Gotowa" : "Ready",
        PrinterState.Printing => polish ? "Drukowanie" : "Printing",
        PrinterState.Paused => polish ? "Wstrzymana" : "Paused",
        PrinterState.Finished => polish ? "Zakończono" : "Finished",
        PrinterState.Error => polish ? "Błąd" : "Error",
        PrinterState.Offline => polish ? "Offline" : "Offline",
        _ => "—"
    };

    /// <summary>Accent colour (hex, no #) used on the printer card, mirroring the macOS symbols.</summary>
    public static string AccentHex(this PrinterState state) => state switch
    {
        PrinterState.Idle => "30D158",
        PrinterState.Printing => "0A84FF",
        PrinterState.Paused => "FF9F0A",
        PrinterState.Finished => "30D158",
        PrinterState.Error => "FF453A",
        PrinterState.Offline => "8E8E93",
        _ => "8E8E93"
    };
}

/// <summary>Live telemetry for one printer. Reference type so incremental MQTT updates merge in place.</summary>
public sealed class PrinterTelemetry
{
    public PrinterState State { get; set; } = PrinterState.Offline;
    public int Progress { get; set; }
    public int? RemainingMinutes { get; set; }
    public double? NozzleTemperature { get; set; }
    public double? NozzleTargetTemperature { get; set; }
    public double? BedTemperature { get; set; }
    public double? BedTargetTemperature { get; set; }
    public double? ChamberTemperature { get; set; }
    public int? CurrentLayer { get; set; }
    public int? TotalLayers { get; set; }
    public int? CurrentStage { get; set; }
    public string? JobName { get; set; }
    public ulong ErrorCode { get; set; }
    public List<string> HmsCodes { get; set; } = new();
    public List<AmsSlot> AmsSlots { get; set; } = new();
    public int? AmsHumidity { get; set; }
    public double? AmsTemperature { get; set; }
    public DateTime? LastUpdated { get; set; }

    public PrinterTelemetry Clone()
    {
        return new PrinterTelemetry
        {
            State = State,
            Progress = Progress,
            RemainingMinutes = RemainingMinutes,
            NozzleTemperature = NozzleTemperature,
            NozzleTargetTemperature = NozzleTargetTemperature,
            BedTemperature = BedTemperature,
            BedTargetTemperature = BedTargetTemperature,
            ChamberTemperature = ChamberTemperature,
            CurrentLayer = CurrentLayer,
            TotalLayers = TotalLayers,
            CurrentStage = CurrentStage,
            JobName = JobName,
            ErrorCode = ErrorCode,
            HmsCodes = new List<string>(HmsCodes),
            AmsSlots = AmsSlots.Select(s => s.Clone()).ToList(),
            AmsHumidity = AmsHumidity,
            AmsTemperature = AmsTemperature,
            LastUpdated = LastUpdated
        };
    }
}

public sealed class AmsSlot
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string Material { get; set; } = "";
    public string ColorHex { get; set; } = "8E8E93FF";
    public int? RemainingPercent { get; set; }
    public bool IsActive { get; set; }
    public bool IsExternal { get; set; }

    public AmsSlot Clone() => (AmsSlot)MemberwiseClone();
}

public sealed class SavedPrinter
{
    [JsonPropertyName("serial")] public string Serial { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("model")] public string Model { get; set; } = "Bambu Lab";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
}

public sealed class DiscoveredPrinter
{
    public string Serial { get; set; } = "";
    public string Name { get; set; } = "";
    public string Model { get; set; } = "Bambu Lab";
    public string Host { get; set; } = "";
}

public static class PrinterCapabilities
{
    /// <summary>
    /// The A1 family and the P1 family have no chamber temperature sensor and report a placeholder
    /// that should not be shown; every other model (X1, X2, P2, H2D…) has one, so default to
    /// showing it. Detected from the serial prefix (030 A1 mini, 039 A1, 01S/01P P1S/P1P).
    /// </summary>
    public static bool HasChamberSensor(string serial)
    {
        string prefix = (serial.Length >= 3 ? serial[..3] : serial).ToUpperInvariant();
        return prefix is not ("030" or "039" or "01S" or "01P");
    }
}
