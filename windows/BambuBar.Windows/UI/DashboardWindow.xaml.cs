using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using BambuBar.Models;
using BambuBar.Services;

namespace BambuBar.UI;

public partial class DashboardWindow : Window
{
    private readonly PrinterStore _store;

    public DashboardWindow(PrinterStore store)
    {
        InitializeComponent();
        _store = store;
        // Rounded corners, an acrylic backdrop and a native shadow — the Windows 11 flyout look,
        // closer to the macOS popover than a plain window. No-ops safely on older Windows.
        SourceInitialized += (_, _) => ApplyModernChrome();
        ScanButton.Click += (_, _) => _store.Scan();
        AddButton.Click += (_, _) => OpenAddWindow();
        _store.Updated += OnStoreUpdated;
        Closed += (_, _) => _store.Updated -= OnStoreUpdated;
        // Popover behaviour: dismiss when the user clicks away, like the macOS menu-bar panel —
        // but stay open while one of our own dialogs (add printer) sits on top.
        Deactivated += (_, _) =>
        {
            foreach (Window owned in OwnedWindows)
                if (owned.IsVisible) return;
            _lastHidden = DateTime.Now;
            Hide();
        };
        Rebuild();
    }

    private DateTime _lastHidden = DateTime.MinValue;

    /// <summary>Positions the panel above the tray (bottom-right of the work area) and shows it,
    /// or hides it if already visible — so a tray click toggles it like a popover.</summary>
    public void TogglePopover()
    {
        if (IsVisible)
        {
            Hide();
            return;
        }
        // A click on the tray icon while the panel is open first deactivates it (hiding it above);
        // ignore that same click here so the panel stays hidden instead of immediately reopening.
        if ((DateTime.Now - _lastHidden).TotalMilliseconds < 250) return;
        ShowPopover();
    }

    /// <summary>Positions and shows the panel unconditionally (used by menu items).</summary>
    public void ShowPopover()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Right - Width - 8;
        Top = area.Bottom - Height - 8;
        Show();
        Activate();
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void ApplyModernChrome()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int dark = 1, round = 2, acrylic = 3;  // dark mode, rounded corners, acrylic backdrop
        try
        {
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));    // DWMWA_USE_IMMERSIVE_DARK_MODE
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));   // DWMWA_WINDOW_CORNER_PREFERENCE
            DwmSetWindowAttribute(hwnd, 38, ref acrylic, sizeof(int)); // DWMWA_SYSTEMBACKDROP_TYPE
        }
        catch { /* older Windows without these attributes — plain window is fine */ }
    }

    public void RefreshLanguage() => Rebuild();

    private void OnStoreUpdated(object? sender, EventArgs e) => Dispatcher.Invoke(Rebuild);

    private void OpenAddWindow()
    {
        var window = new AddPrinterWindow(_store) { Owner = this };
        window.ShowDialog();
    }

    private void Rebuild()
    {
        StatusLine.Text = _store.IsScanning
            ? AppSettings.Text("Skanowanie…", "Scanning…")
            : (_store.GlobalMessage ?? AppSettings.Text($"{_store.Printers.Count} drukarek • {_store.ActivePrintCount} drukuje",
                                                        $"{_store.Printers.Count} printers • {_store.ActivePrintCount} printing"));
        CardsPanel.Children.Clear();

        if (_store.Printers.Count == 0)
        {
            CardsPanel.Children.Add(new TextBlock
            {
                Text = AppSettings.Text("Brak drukarek. Kliknij +, aby dodać.", "No printers. Click + to add one."),
                Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0x9A, 0x9E)),
                Margin = new Thickness(8)
            });
        }

        foreach (var printer in _store.Printers)
            CardsPanel.Children.Add(BuildCard(printer));
    }

    private Border BuildCard(SavedPrinter printer)
    {
        var telemetry = _store.Telemetry.TryGetValue(printer.Serial, out var t) ? t : new PrinterTelemetry();
        _store.ConnectionMessages.TryGetValue(printer.Serial, out var message);
        bool pl = AppSettings.Polish;

        var stack = new StackPanel();

        // Header: name + state pill
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBlock { Text = printer.Name, FontWeight = FontWeights.SemiBold, FontSize = 14, TextTrimming = TextTrimming.CharacterEllipsis };
        header.Children.Add(name);
        var pill = StatePill(telemetry.State, pl);
        Grid.SetColumn(pill, 1);
        header.Children.Add(pill);
        stack.Children.Add(header);

        // Job name
        stack.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(telemetry.JobName) ? AppSettings.Text("Brak aktywnego zadania", "No active job") : telemetry.JobName!,
            Foreground = Muted(),
            FontSize = 11,
            Margin = new Thickness(0, 4, 0, 6),
            TextTrimming = TextTrimming.CharacterEllipsis
        });

        // Progress
        var progressRow = new Grid { Margin = new Thickness(0, 0, 0, 6) };
        progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var bar = new ProgressBar { Minimum = 0, Maximum = 100, Value = telemetry.Progress, Height = 6, Foreground = Accent(telemetry.State), Background = new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3C)), BorderThickness = new Thickness(0) };
        progressRow.Children.Add(bar);
        var percent = new TextBlock { Text = $"{telemetry.Progress}%", FontSize = 11, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(percent, 1);
        progressRow.Children.Add(percent);
        stack.Children.Add(progressRow);

        // Info line: ETA + layers
        stack.Children.Add(InfoRow(
            (Glyph: "⏱", Value: FormatEta(telemetry.RemainingMinutes)),
            (Glyph: "▤", Value: telemetry.CurrentLayer is { } cl && telemetry.TotalLayers is { } tl ? $"{cl}/{tl}" : "—")));

        // Temps
        stack.Children.Add(InfoRow(
            (Glyph: "🌡", Value: FormatTemp(telemetry.NozzleTemperature, telemetry.NozzleTargetTemperature)),
            (Glyph: "▬", Value: FormatTemp(telemetry.BedTemperature, telemetry.BedTargetTemperature))));

        // AMS
        if (telemetry.AmsSlots.Count > 0)
        {
            var ams = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            ams.Children.Add(new TextBlock { Text = "AMS", FontSize = 10, Foreground = Muted(), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
            foreach (var slot in telemetry.AmsSlots)
                ams.Children.Add(AmsChip(slot));
            stack.Children.Add(ams);
        }

        // Connection message
        if (!string.IsNullOrEmpty(message))
            stack.Children.Add(new TextBlock { Text = message, FontSize = 10, Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A)), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) });

        // Actions: a single "…" menu mirroring the macOS card menu.
        var moreButton = new Button
        {
            Content = "⋯", FontSize = 16, Width = 34, Height = 26,
            HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0)
        };
        var menu = BuildActionsPopup(printer);
        menu.PlacementTarget = moreButton;
        menu.Placement = PlacementMode.Bottom;
        moreButton.Click += (_, _) => menu.IsOpen = !menu.IsOpen;
        var actionsHost = new Grid();
        actionsHost.Children.Add(moreButton);
        actionsHost.Children.Add(menu);
        stack.Children.Add(actionsHost);

        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xD8, 0x3A, 0x3A, 0x3C)),
            CornerRadius = new CornerRadius(14),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x20, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(13),
            Margin = new Thickness(7),
            Width = 232,
            Child = stack
        };
    }

    private static Border StatePill(PrinterState state, bool pl)
    {
        var color = ParseHex(state.AccentHex() + "FF");
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x33, color.R, color.G, color.B)),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(6, 2, 6, 2),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = state.Label(pl), FontSize = 10, Foreground = new SolidColorBrush(color), FontWeight = FontWeights.SemiBold }
        };
    }

    private static Grid InfoRow((string Glyph, string Value) left, (string Glyph, string Value) right)
    {
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Cell(left.Glyph, left.Value, 0));
        grid.Children.Add(Cell(right.Glyph, right.Value, 1));
        return grid;
    }

    private static StackPanel Cell(string glyph, string value, int column)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(new TextBlock { Text = glyph + " ", FontSize = 11, Foreground = Muted() });
        panel.Children.Add(new TextBlock { Text = value, FontSize = 11 });
        Grid.SetColumn(panel, column);
        return panel;
    }

    private static Border AmsChip(AmsSlot slot)
    {
        var color = ParseHex(slot.ColorHex);
        var border = new Border
        {
            Background = new SolidColorBrush(color),
            CornerRadius = new CornerRadius(4),
            Width = 26,
            Height = 20,
            Margin = new Thickness(2),
            BorderThickness = new Thickness(slot.IsActive ? 2 : 0),
            BorderBrush = new SolidColorBrush(Colors.White),
            ToolTip = $"{slot.Label} • {slot.Material}" + (slot.RemainingPercent is { } r ? $" • {r}%" : "")
        };
        border.Child = new TextBlock
        {
            Text = slot.Label,
            FontSize = 9,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(Luminance(color) > 0.6 ? Colors.Black : Colors.White)
        };
        return border;
    }

    /// <summary>A dark, rounded popup menu for one printer card, mirroring the macOS "…" card menu:
    /// reconnect, camera (Bambu), open in each installed slicer, copy IP, edit, remove.</summary>
    private Popup BuildActionsPopup(SavedPrinter printer)
    {
        var items = new StackPanel();
        var popup = new Popup
        {
            StaysOpen = false,
            AllowsTransparency = true,
            PopupAnimation = PopupAnimation.Fade,
            Child = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xF2, 0x2C, 0x2C, 0x2E)),
                CornerRadius = new CornerRadius(10),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x2A, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(4),
                MinWidth = 200,
                Child = items
            }
        };

        void Item(string text, Action action)
        {
            var button = new Button
            {
                Content = text,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(12, 7, 12, 7),
                Margin = new Thickness(2, 1, 2, 1),
                FontSize = 12
            };
            button.Click += (_, _) => { popup.IsOpen = false; action(); };
            items.Children.Add(button);
        }

        Item(AppSettings.Text("Połącz ponownie", "Reconnect"), () => _store.Reconnect(printer));

        var slicers = SlicerLauncher.Installed();
        if (printer.Kind == PrinterKind.Bambu)
        {
            var bambu = slicers.FirstOrDefault(s => s.Name == "Bambu Studio");
            if (bambu is not null)
                Item(AppSettings.Text("Kamera w Bambu Studio", "Camera in Bambu Studio"), () => SlicerLauncher.Open(bambu.Path));
        }
        foreach (var slicer in slicers)
            Item(AppSettings.Text($"Otwórz w {slicer.Name}", $"Open in {slicer.Name}"), () => SlicerLauncher.Open(slicer.Path));

        if (!string.IsNullOrEmpty(printer.Host))
            Item(AppSettings.Text("Kopiuj adres IP", "Copy IP address"), () => { try { Clipboard.SetText(printer.Host); } catch { } });

        Item(AppSettings.Text("Edytuj drukarkę", "Edit printer"), () =>
        {
            var window = new AddPrinterWindow(_store, printer) { Owner = this };
            window.ShowDialog();
        });
        Item(AppSettings.Text("Usuń drukarkę", "Remove printer"), () =>
        {
            var confirm = MessageBox.Show(this,
                AppSettings.Text($"Usunąć drukarkę {printer.Name}?", $"Remove printer {printer.Name}?"),
                "BambuBar", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (confirm == MessageBoxResult.Yes) _store.Remove(printer);
        });

        return popup;
    }

    private static string FormatEta(int? minutes)
    {
        if (minutes is not { } m || m <= 0) return "—";
        return m >= 60 ? $"{m / 60}h {m % 60}m" : $"{m}m";
    }

    private static string FormatTemp(double? current, double? target)
    {
        if (current is not { } c) return "—";
        string value = c.ToString("0", CultureInfo.InvariantCulture) + "°";
        if (target is { } t && t > 0) value += "/" + t.ToString("0", CultureInfo.InvariantCulture) + "°";
        return value;
    }

    private static SolidColorBrush Muted() => new(Color.FromRgb(0x9A, 0x9A, 0x9E));
    private static SolidColorBrush Accent(PrinterState state) => new(ParseHex(state.AccentHex() + "FF"));

    private static Color ParseHex(string hex)
    {
        hex = hex.TrimStart('#');
        try
        {
            if (hex.Length >= 8)
            {
                byte r = Convert.ToByte(hex.Substring(0, 2), 16);
                byte g = Convert.ToByte(hex.Substring(2, 2), 16);
                byte b = Convert.ToByte(hex.Substring(4, 2), 16);
                byte a = Convert.ToByte(hex.Substring(6, 2), 16);
                return Color.FromArgb(a, r, g, b);
            }
            if (hex.Length >= 6)
            {
                byte r = Convert.ToByte(hex.Substring(0, 2), 16);
                byte g = Convert.ToByte(hex.Substring(2, 2), 16);
                byte b = Convert.ToByte(hex.Substring(4, 2), 16);
                return Color.FromRgb(r, g, b);
            }
        }
        catch { /* fall through */ }
        return Color.FromRgb(0x8E, 0x8E, 0x93);
    }

    private static double Luminance(Color c) => (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) / 255.0;
}
