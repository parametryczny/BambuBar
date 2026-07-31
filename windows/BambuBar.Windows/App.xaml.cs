using System.Windows;
using System.Windows.Threading;
using BambuBar.Services;
using BambuBar.UI;

namespace BambuBar;

public partial class App : Application
{
    private PrinterStore? _store;
    private TrayIcon? _tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Windows-1252 is not registered by default on .NET 8; the status parser uses it to
        // repair mis-encoded print names.
        System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);

        var dispatcher = Dispatcher.CurrentDispatcher;
        _store = new PrinterStore(action =>
        {
            if (dispatcher.CheckAccess()) action();
            else dispatcher.BeginInvoke(action);
        });

        _tray = new TrayIcon(_store);
        NotificationService.Sink = (title, body, subtitle) => _tray.ShowNotification(title, body, subtitle);

        if (LaunchAtLogin.IsEnabled) LaunchAtLogin.SetEnabled(true); // refresh path

        _store.ReconnectAll();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        base.OnExit(e);
    }
}
