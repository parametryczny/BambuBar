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
    public async Task<List<DiscoveredPrinter>> ScanAsync()
    {
        var prefixes = LocalIPv4Prefixes();
        if (prefixes.Count == 0) return new List<DiscoveredPrinter>();

        var hosts = prefixes
            .SelectMany(prefix => Enumerable.Range(1, 254).Select(i => $"{prefix}.{i}"))
            .Distinct()
            .ToList();

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
