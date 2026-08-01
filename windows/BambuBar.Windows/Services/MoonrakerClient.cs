using System.Net.Http;
using System.Text.Json;
using BambuBar.Models;

namespace BambuBar.Services;

/// <summary>Polls a Klipper printer's Moonraker API and reports status through MqttEvent, so
/// PrinterStore treats Klipper and Bambu connections identically. Mirrors the macOS client.</summary>
public sealed class MoonrakerClient : IPrinterConnection
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };

    private readonly SavedPrinter _printer;
    private readonly Action<MqttEvent> _onEvent;
    private readonly CancellationTokenSource _cts = new();
    private PrinterTelemetry _telemetry = new();
    private bool _connectedReported;
    private bool _disconnectReported;

    public MoonrakerClient(SavedPrinter printer, Action<MqttEvent> onEvent)
    {
        _printer = printer;
        _onEvent = onEvent;
    }

    public void Start() => _ = Task.Run(RunAsync);

    public void Stop()
    {
        try { _cts.Cancel(); } catch { }
    }

    private string BaseUrl => $"http://{_printer.Host}:{_printer.Port ?? 7125}";

    private async Task RunAsync()
    {
        var query = await BuildQueryUrlAsync();
        if (query is null)
        {
            ReportDisconnected(AppSettings.Text($"Nie znaleziono API Moonraker (port {_printer.Port ?? 7125})",
                $"Moonraker API not found (port {_printer.Port ?? 7125})"));
            return;
        }
        while (!_cts.IsCancellationRequested)
        {
            try
            {
                var data = await GetAsync(query);
                var updated = MoonrakerStatusParser.Telemetry(data, _telemetry);
                if (updated is not null)
                {
                    _telemetry = updated;
                    if (!_connectedReported) { _connectedReported = true; _onEvent(new MqttEvent { Type = MqttEventType.Connected }); }
                    _onEvent(new MqttEvent { Type = MqttEventType.Telemetry, Telemetry = updated });
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { ReportDisconnected(ex.Message); return; }
            try { await Task.Delay(TimeSpan.FromSeconds(2), _cts.Token); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task<string?> BuildQueryUrlAsync()
    {
        var wanted = new List<string> { "print_stats", "virtual_sdcard", "display_status", "extruder", "heater_bed", "mmu" };
        try
        {
            var listData = await GetAsync($"{BaseUrl}/printer/objects/list");
            using var doc = JsonDocument.Parse(listData);
            if (doc.RootElement.TryGetProperty("result", out var res)
                && res.TryGetProperty("objects", out var objects) && objects.ValueKind == JsonValueKind.Array)
            {
                var available = objects.EnumerateArray().Select(o => o.GetString() ?? "").ToHashSet();
                wanted = wanted.Where(available.Contains).ToList();
                foreach (var name in available)
                    if (name.ToLowerInvariant().Contains("chamber")
                        && (name.StartsWith("temperature_sensor") || name.StartsWith("heater_generic")))
                        wanted.Add(name);
            }
        }
        catch { /* fall back to the default object set */ }

        if (wanted.Count == 0) return null;
        var query = string.Join("&", wanted.Select(Uri.EscapeDataString));
        return $"{BaseUrl}/printer/objects/query?{query}";
    }

    private async Task<byte[]> GetAsync(string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (!string.IsNullOrEmpty(_printer.ApiKey)) request.Headers.Add("X-Api-Key", _printer.ApiKey);
        using var response = await Http.SendAsync(request, _cts.Token);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync(_cts.Token);
    }

    private void ReportDisconnected(string? reason)
    {
        if (_disconnectReported) return;
        _disconnectReported = true;
        _onEvent(new MqttEvent { Type = MqttEventType.Disconnected, Reason = reason });
    }
}
