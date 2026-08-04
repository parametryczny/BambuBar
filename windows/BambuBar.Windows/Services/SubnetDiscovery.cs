using System.Net.Security;
using System.Net.Sockets;
using System.Net.NetworkInformation;
using System.Net;
using System.Security.Cryptography.X509Certificates;
using BambuBar.Models;

namespace BambuBar.Services;

/// <summary>
/// Finds Bambu printers even when multicast is filtered: a Bambu MQTTs certificate exposes the
/// serial number as its subject CN. Ported from the macOS BambuSubnetDiscovery.
/// </summary>
public sealed class SubnetDiscovery
{
    private const int MaxCustomHosts = 4096;

    public async Task<List<DiscoveredPrinter>> ScanAsync()
    {
        var hosts = HostsToScan();
        if (hosts.Count == 0) return new List<DiscoveredPrinter>();

        var found = new Dictionary<string, DiscoveredPrinter>();
        var gate = new object();
        using var limiter = new SemaphoreSlim(128);

        var tasks = hosts.Select(async host =>
        {
            await limiter.WaitAsync();
            try
            {
                var printer = await ProbeAsync(host);
                if (printer is not null)
                    lock (gate) found[printer.Serial] = printer;
            }
            finally { limiter.Release(); }
        });
        await Task.WhenAll(tasks);

        return found.Values
            .OrderBy(p => p.Host, new HostComparer())
            .ToList();
    }

    internal static bool IsValidTargetExpression(string input)
    {
        foreach (var token in ParseTokens(input))
        {
            if (token.Contains('/'))
            {
                if (!TryParseCidr(token, out _, out _)) return false;
                continue;
            }
            if (token.Contains('-'))
            {
                if (!TryParseRange(token, out _, out _)) return false;
                continue;
            }
            if (!TryParseIPv4(token, out _)) return false;
        }
        return true;
    }

    private static List<string> HostsToScan()
    {
        var prefixes = LocalIPv4Prefixes();
        var automaticHosts = prefixes
            .SelectMany(prefix => Enumerable.Range(1, 254).Select(i => $"{prefix}.{i}"))
            .Distinct()
            .ToList();

        var configuredTargets = AppSettings.SubnetScanTargets;
        if (string.IsNullOrWhiteSpace(configuredTargets)
            || !TryExpandTargets(configuredTargets, MaxCustomHosts, out var configured)
            || configured.Count == 0)
        {
            return automaticHosts;
        }

        return automaticHosts
            .Concat(configured)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static bool TryExpandTargets(string input, int maxHosts, out List<string> hosts)
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var token in ParseTokens(input))
        {
            if (token.Contains('/'))
            {
                if (!TryParseCidr(token, out var network, out var prefixLength))
                {
                    hosts = new List<string>();
                    return false;
                }
                AddCidrHosts(set, network, prefixLength, maxHosts);
            }
            else if (token.Contains('-'))
            {
                if (!TryParseRange(token, out var start, out var end))
                {
                    hosts = new List<string>();
                    return false;
                }
                AddRangeHosts(set, start, end, maxHosts);
            }
            else
            {
                if (!TryParseIPv4(token, out var single))
                {
                    hosts = new List<string>();
                    return false;
                }
                if (set.Count < maxHosts) set.Add(ToIPv4String(single));
            }

            if (set.Count >= maxHosts) break;
        }

        hosts = set.ToList();
        hosts.Sort(new HostComparer());
        return true;
    }

    private static IEnumerable<string> ParseTokens(string input)
        => input.Split(new[] { ',', ';', '\n', '\r', '\t', ' ' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static bool TryParseCidr(string token, out uint network, out int prefixLength)
    {
        network = 0;
        prefixLength = 0;

        var parts = token.Split('/', StringSplitOptions.TrimEntries);
        if (parts.Length != 2) return false;
        if (!TryParseIPv4(parts[0], out var address)) return false;
        if (!int.TryParse(parts[1], out prefixLength) || prefixLength < 0 || prefixLength > 32) return false;

        uint mask = prefixLength == 0 ? 0U : uint.MaxValue << (32 - prefixLength);
        network = address & mask;
        return true;
    }

    private static bool TryParseRange(string token, out uint start, out uint end)
    {
        start = 0;
        end = 0;

        var parts = token.Split('-', StringSplitOptions.TrimEntries);
        if (parts.Length != 2) return false;
        if (!TryParseIPv4(parts[0], out start)) return false;
        if (!TryParseIPv4(parts[1], out end)) return false;
        if (start > end) return false;
        return true;
    }

    private static void AddCidrHosts(HashSet<string> set, uint network, int prefixLength, int maxHosts)
    {
        uint hostBits = (uint)(32 - prefixLength);
        uint size = hostBits == 32 ? uint.MaxValue : (1U << (int)hostBits);
        if (prefixLength == 0) size = uint.MaxValue;

        uint first = network;
        uint last = size == uint.MaxValue ? uint.MaxValue : network + size - 1;

        if (prefixLength <= 30 && size >= 2)
        {
            first = network + 1;
            last = network + size - 2;
        }

        AddRangeHosts(set, first, last, maxHosts);
    }

    private static void AddRangeHosts(HashSet<string> set, uint start, uint end, int maxHosts)
    {
        if (end < start) return;
        for (uint value = start; value <= end; value++)
        {
            if (set.Count >= maxHosts) return;
            set.Add(ToIPv4String(value));
            if (value == uint.MaxValue) return;
        }
    }

    private static bool TryParseIPv4(string text, out uint value)
    {
        value = 0;
        if (!IPAddress.TryParse(text, out var ip)) return false;
        var bytes = ip.GetAddressBytes();
        if (bytes.Length != 4) return false;
        value = ((uint)bytes[0] << 24)
              | ((uint)bytes[1] << 16)
              | ((uint)bytes[2] << 8)
              | bytes[3];
        return true;
    }

    private static string ToIPv4String(uint value)
        => $"{(value >> 24) & 255}.{(value >> 16) & 255}.{(value >> 8) & 255}.{value & 255}";

    private static async Task<DiscoveredPrinter?> ProbeAsync(string host)
    {
        string? serial = null;
        TcpClient? tcp = null;
        SslStream? ssl = null;
        try
        {
            tcp = new TcpClient();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2.0));
            await tcp.ConnectAsync(host, 8883, timeout.Token);
            ssl = new SslStream(tcp.GetStream(), false, (_, certificate, _, _) =>
            {
                if (certificate is X509Certificate cert)
                {
                    var x = new X509Certificate2(cert);
                    serial = x.GetNameInfo(X509NameType.SimpleName, false)?.Trim();
                }
                return true;
            });
            await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = host }, timeout.Token);
        }
        catch { /* not a printer / unreachable */ }
        finally
        {
            try { ssl?.Dispose(); } catch { }
            try { tcp?.Close(); } catch { }
        }

        if (serial is null || serial.Length < 10 || !serial.All(char.IsLetterOrDigit)) return null;
        return new DiscoveredPrinter
        {
            Serial = serial,
            Name = $"Bambu {serial[^4..]}",
            Model = "Bambu Lab",
            Host = host
        };
    }

    private static List<string> LocalIPv4Prefixes()
    {
        var prefixes = new HashSet<string>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var addr in ni.GetIPProperties().UnicastAddresses)
            {
                if (addr.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var parts = addr.Address.ToString().Split('.');
                if (parts.Length == 4) prefixes.Add(string.Join('.', parts.Take(3)));
            }
        }
        return prefixes.ToList();
    }

    private sealed class HostComparer : IComparer<string>
    {
        public int Compare(string? x, string? y)
        {
            IPAddress.TryParse(x, out var a);
            IPAddress.TryParse(y, out var b);
            var ab = a?.GetAddressBytes();
            var bb = b?.GetAddressBytes();
            if (ab is null || bb is null) return string.CompareOrdinal(x, y);
            for (int i = 0; i < 4; i++)
                if (ab[i] != bb[i]) return ab[i].CompareTo(bb[i]);
            return 0;
        }
    }
}
