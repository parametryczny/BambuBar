using System.IO;
using System.Text.Json;

namespace BambuBar.Services;

/// <summary>Reads locally stored printer access codes and IPs from Bambu Studio's config.</summary>
public static class BambuStudioConfig
{
    public readonly record struct Device(string Serial, string AccessCode, string? Host);

    /// <summary>Every printer with a saved access code, paired with its last known IP so printers
    /// can be imported without a network scan.</summary>
    public static List<Device> Devices()
    {
        var root = ReadRoot();
        var codes = StringDictionary(root, "access_code");
        foreach (var kv in StringDictionary(root, "user_access_code")) codes[kv.Key] = kv.Value; // user codes win
        codes = codes.Where(kv => kv.Key.Length > 0 && kv.Value.Length > 0).ToDictionary(kv => kv.Key, kv => kv.Value);
        if (codes.Count == 0)
            throw new BambuStudioConfigException(AppSettings.Text("Bambu Studio nie ma zapisanych kodów drukarek.", "Bambu Studio has no stored printer codes."));

        var ips = StringDictionary(root, "ip_address");
        return codes.Select(kv =>
        {
            string? host = ips.TryGetValue(kv.Key, out var h) && h.Length > 0 ? h : null;
            return new Device(kv.Key, kv.Value, host);
        }).ToList();
    }

    public static Dictionary<string, string> AccessCodes()
        => Devices().ToDictionary(d => d.Serial, d => d.AccessCode);

    private static JsonElement ReadRoot()
    {
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "BambuStudio", "BambuStudio.conf");
        if (!File.Exists(path))
            throw new BambuStudioConfigException(AppSettings.Text("Nie znaleziono konfiguracji Bambu Studio.", "Bambu Studio configuration not found."));
        try { return JsonDocument.Parse(File.ReadAllText(path)).RootElement.Clone(); }
        catch { throw new BambuStudioConfigException(AppSettings.Text("Nie udało się odczytać konfiguracji Bambu Studio.", "Could not read the Bambu Studio configuration.")); }
    }

    private static Dictionary<string, string> StringDictionary(JsonElement root, string key)
    {
        var dict = new Dictionary<string, string>();
        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty(key, out var obj) && obj.ValueKind == JsonValueKind.Object)
            foreach (var prop in obj.EnumerateObject())
                if (prop.Value.ValueKind == JsonValueKind.String)
                    dict[prop.Name] = prop.Value.GetString()!;
        return dict;
    }
}

public sealed class BambuStudioConfigException : Exception
{
    public BambuStudioConfigException(string message) : base(message) { }
}
