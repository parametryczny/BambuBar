using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using BambuBar.Services;
using Application = System.Windows.Application;

namespace BambuBar.UI;

/// <summary>System tray presence — the Windows counterpart of the macOS menu bar item.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly PrinterStore _store;
    private readonly NotifyIcon _notifyIcon;
    private DashboardWindow? _dashboard;
    private SettingsWindow? _settings;

    public TrayIcon(PrinterStore store)
    {
        _store = store;
        _notifyIcon = new NotifyIcon
        {
            Icon = BuildIcon(),
            Visible = true,
            Text = "BambuBar"
        };
        _notifyIcon.DoubleClick += (_, _) => ShowDashboard();
        _notifyIcon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowDashboard(); };
        _notifyIcon.ContextMenuStrip = BuildMenu();
        _store.Updated += (_, _) => RefreshTooltip();
        RefreshTooltip();
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        bool pl = AppSettings.Polish;

        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Pokaż drukarki", "Show printers"), null, (_, _) => ShowDashboard()));
        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Szukaj drukarek…", "Scan for printers…"), null, (_, _) => { ShowDashboard(); _store.Scan(); }));
        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Połącz ponownie", "Reconnect all"), null, (_, _) => _store.ReconnectAll()));
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Ustawienia…", "Settings…"), null, (_, _) => ShowSettings()));

        var language = new ToolStripMenuItem(AppSettings.Text("Język: Polski", "Language: English"));
        language.Click += (_, _) => { AppSettings.Polish = !AppSettings.Polish; RebuildMenu(); };
        menu.Items.Add(language);

        var startup = new ToolStripMenuItem(AppSettings.Text("Uruchamiaj z Windows", "Start with Windows"))
        {
            Checked = LaunchAtLogin.IsEnabled,
            CheckOnClick = true
        };
        startup.Click += (_, _) => LaunchAtLogin.SetEnabled(startup.Checked);
        menu.Items.Add(startup);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Zakończ", "Quit"), null, (_, _) => Application.Current.Shutdown()));
        _ = pl;
        return menu;
    }

    private void RebuildMenu()
    {
        _notifyIcon.ContextMenuStrip?.Dispose();
        _notifyIcon.ContextMenuStrip = BuildMenu();
        _dashboard?.RefreshLanguage();
    }

    private void ShowDashboard()
    {
        if (_dashboard is null)
        {
            _dashboard = new DashboardWindow(_store);
            _dashboard.Closed += (_, _) => _dashboard = null;
        }
        _dashboard.Show();
        _dashboard.Activate();
        _dashboard.WindowState = System.Windows.WindowState.Normal;
    }

    private void ShowSettings()
    {
        if (_settings is null)
        {
            _settings = new SettingsWindow();
            _settings.Closed += (_, _) => _settings = null;
        }
        _settings.Show();
        _settings.Activate();
        _settings.WindowState = System.Windows.WindowState.Normal;
    }

    public void ShowNotification(string title, string body, string? subtitle)
    {
        string text = string.IsNullOrEmpty(subtitle) ? body : $"{subtitle}\n{body}";
        _notifyIcon.ShowBalloonTip(5000, title, text, ToolTipIcon.Info);
    }

    private void RefreshTooltip()
    {
        int active = _store.ActivePrintCount;
        int total = _store.Printers.Count;
        _notifyIcon.Text = active > 0
            ? AppSettings.Text($"BambuBar — {active} drukuje", $"BambuBar — {active} printing")
            : AppSettings.Text($"BambuBar — {total} drukarek", $"BambuBar — {total} printers");
    }

    private static Icon BuildIcon()
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var back = new SolidBrush(Color.FromArgb(230, 28, 28, 30));
            using var path = RoundedRect(new Rectangle(1, 1, 30, 30), 7);
            g.FillPath(back, path);
            using var font = new Font("Segoe UI", 12, FontStyle.Bold, GraphicsUnit.Pixel);
            using var text = new SolidBrush(Color.FromArgb(255, 245, 245, 247));
            var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("BL", font, text, new RectangleF(0, 0, 32, 32), format);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    private static GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        int d = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public void Dispose()
    {
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
    }
}
