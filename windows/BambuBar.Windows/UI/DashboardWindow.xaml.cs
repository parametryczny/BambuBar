using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
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
        MenuBackdrop.MouseLeftButtonDown += (_, _) => HideCardMenu();
        Rebuild();
    }

    private DateTime _lastHidden = DateTime.MinValue;
    private FrameworkElement? _cardMenu;

    private void ShowCardMenu(FrameworkElement anchor, FrameworkElement menu)
    {
        HideCardMenu();
        _cardMenu = menu;
        // Right-align the menu under the "…" button; MinWidth keeps positioning stable pre-layout.
        var corner = anchor.TranslatePoint(new Point(anchor.ActualWidth, anchor.ActualHeight), MenuLayer);
        menu.HorizontalAlignment = HorizontalAlignment.Left;
        menu.VerticalAlignment = VerticalAlignment.Top;
        menu.Margin = new Thickness(Math.Max(4, corner.X - 200), corner.Y + 2, 0, 0);
        MenuLayer.Children.Add(menu);
        MenuLayer.Visibility = Visibility.Visible;
    }

    private void HideCardMenu()
    {
        MenuLayer.Visibility = Visibility.Collapsed;
        if (_cardMenu is not null) { MenuLayer.Children.Remove(_cardMenu); _cardMenu = null; }
    }

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

    public void RefreshLanguage() { _renderedSerials = new(); Rebuild(); }

    private void OnStoreUpdated(object? sender, EventArgs e) => Dispatcher.Invoke(Rebuild);

    private void OpenAddWindow()
    {
        var window = new AddPrinterWindow(_store) { Owner = this };
        window.ShowDialog();
    }

    private readonly Dictionary<string, PrinterCard> _cards = new();
    private List<string> _renderedSerials = new();

    // Reconciles the card list against the printers, then updates each card's values in place.
    // Cards are only rebuilt when the printer set/order changes — telemetry updates (~every 2s)
    // just mutate existing controls, so hovering/clicking the "…" menu stays responsive.
    private void Rebuild()
    {
        bool pl = AppSettings.Polish;
        StatusLine.Text = _store.IsScanning
            ? AppSettings.Text("Skanowanie…", "Scanning…")
            : (_store.GlobalMessage ?? AppSettings.Text($"{_store.Printers.Count} drukarek • {_store.ActivePrintCount} drukuje",
                                                        $"{_store.Printers.Count} printers • {_store.ActivePrintCount} printing"));

        var serials = _store.Printers.Select(p => p.Serial).ToList();
        if (!serials.SequenceEqual(_renderedSerials))
        {
            HideCardMenu();
            CardsPanel.Children.Clear();
            if (_store.Printers.Count == 0)
            {
                _cards.Clear();
                CardsPanel.Children.Add(new TextBlock
                {
                    Text = AppSettings.Text("Brak drukarek. Kliknij +, aby dodać.", "No printers. Click + to add one."),
                    Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0x9A, 0x9E)),
                    Margin = new Thickness(8)
                });
                _renderedSerials = serials;
                return;
            }
            var live = new Dictionary<string, PrinterCard>();
            foreach (var printer in _store.Printers)
            {
                if (!_cards.TryGetValue(printer.Serial, out var card))
                    card = new PrinterCard(this, printer);
                live[printer.Serial] = card;
                CardsPanel.Children.Add(card.Root);
            }
            _cards.Clear();
            foreach (var kv in live) _cards[kv.Key] = kv.Value;
            _renderedSerials = serials;
        }

        foreach (var printer in _store.Printers)
            if (_cards.TryGetValue(printer.Serial, out var card))
            {
                var t = _store.Telemetry.TryGetValue(printer.Serial, out var tel) ? tel : new PrinterTelemetry();
                _store.ConnectionMessages.TryGetValue(printer.Serial, out var msg);
                card.Update(printer, t, msg, pl);
            }
    }

    private void ToggleCardMenu(FrameworkElement anchor, FrameworkElement menu)
    {
        if (MenuLayer.Visibility == Visibility.Visible && ReferenceEquals(_cardMenu, menu)) HideCardMenu();
        else ShowCardMenu(anchor, menu);
    }

    /// <summary>One printer card whose visuals are built once and updated in place, so the panel
    /// doesn't churn on every telemetry tick.</summary>
    private sealed class PrinterCard
    {
        public Border Root { get; }
        private readonly TextBlock _name, _pillText, _job, _percent, _eta, _layers, _nozzle, _bed, _message;
        private readonly Border _pill;
        private readonly ProgressBar _bar;
        private readonly WrapPanel _ams;

        public PrinterCard(DashboardWindow owner, SavedPrinter printer)
        {
            var stack = new StackPanel();

            var header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _name = new TextBlock { FontWeight = FontWeights.SemiBold, FontSize = 14, TextTrimming = TextTrimming.CharacterEllipsis };
            header.Children.Add(_name);
            _pillText = new TextBlock { FontSize = 10, FontWeight = FontWeights.SemiBold };
            _pill = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(6, 2, 6, 2), VerticalAlignment = VerticalAlignment.Center, Child = _pillText };
            Grid.SetColumn(_pill, 1);
            header.Children.Add(_pill);
            stack.Children.Add(header);

            _job = new TextBlock { Foreground = Muted(), FontSize = 11, Margin = new Thickness(0, 4, 0, 6), TextTrimming = TextTrimming.CharacterEllipsis };
            stack.Children.Add(_job);

            var progressRow = new Grid { Margin = new Thickness(0, 0, 0, 6) };
            progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _bar = new ProgressBar { Minimum = 0, Maximum = 100, Height = 6, Background = new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3C)), BorderThickness = new Thickness(0) };
            progressRow.Children.Add(_bar);
            _percent = new TextBlock { FontSize = 11, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(_percent, 1);
            progressRow.Children.Add(_percent);
            stack.Children.Add(progressRow);

            var (etaRow, etaValue, layersValue) = InfoRow("⏱", "▤");
            _eta = etaValue; _layers = layersValue;
            stack.Children.Add(etaRow);
            var (tempRow, nozzleValue, bedValue) = InfoRow("🌡", "▬");
            _nozzle = nozzleValue; _bed = bedValue;
            stack.Children.Add(tempRow);

            _ams = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            stack.Children.Add(_ams);

            _message = new TextBlock { FontSize = 10, Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x9F, 0x0A)), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
            stack.Children.Add(_message);

            var more = new Button { Content = "⋯", FontSize = 16, Width = 34, Height = 26, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
            var menu = owner.BuildCardMenu(printer.Serial);
            more.Click += (_, _) => owner.ToggleCardMenu(more, menu);
            stack.Children.Add(more);

            Root = new Border
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

        public void Update(SavedPrinter printer, PrinterTelemetry t, string? message, bool pl)
        {
            _name.Text = printer.Name;
            var accent = ParseHex(t.State.AccentHex() + "FF");
            _pill.Background = new SolidColorBrush(Color.FromArgb(0x33, accent.R, accent.G, accent.B));
            _pillText.Text = t.State.Label(pl);
            _pillText.Foreground = new SolidColorBrush(accent);
            _job.Text = string.IsNullOrEmpty(t.JobName) ? AppSettings.Text("Brak aktywnego zadania", "No active job") : t.JobName!;
            _bar.Value = t.Progress;
            _bar.Foreground = new SolidColorBrush(accent);
            _percent.Text = $"{t.Progress}%";
            _eta.Text = FormatEta(t.RemainingMinutes);
            _layers.Text = t.CurrentLayer is { } cl && t.TotalLayers is { } tl ? $"{cl}/{tl}" : "—";
            _nozzle.Text = FormatTemp(t.NozzleTemperature, t.NozzleTargetTemperature);
            _bed.Text = FormatTemp(t.BedTemperature, t.BedTargetTemperature);

            _ams.Children.Clear();
            if (t.AmsSlots.Count > 0)
            {
                _ams.Visibility = Visibility.Visible;
                _ams.Children.Add(new TextBlock { Text = "AMS", FontSize = 10, Foreground = Muted(), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
                foreach (var slot in t.AmsSlots) _ams.Children.Add(AmsChip(slot));
            }
            else _ams.Visibility = Visibility.Collapsed;

            if (string.IsNullOrEmpty(message)) _message.Visibility = Visibility.Collapsed;
            else { _message.Text = message; _message.Visibility = Visibility.Visible; }
        }
    }

    private static (Grid Row, TextBlock Left, TextBlock Right) InfoRow(string leftGlyph, string rightGlyph)
    {
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var (leftPanel, leftValue) = Cell(leftGlyph, 0);
        var (rightPanel, rightValue) = Cell(rightGlyph, 1);
        grid.Children.Add(leftPanel);
        grid.Children.Add(rightPanel);
        return (grid, leftValue, rightValue);
    }

    private static (StackPanel Panel, TextBlock Value) Cell(string glyph, int column)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(new TextBlock { Text = glyph + " ", FontSize = 11, Foreground = Muted() });
        var value = new TextBlock { FontSize = 11 };
        panel.Children.Add(value);
        Grid.SetColumn(panel, column);
        return (panel, value);
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

    /// <summary>A dark, rounded menu for one printer card, mirroring the macOS "…" card menu:
    /// reconnect, camera (Bambu), open in each installed slicer, copy IP, edit, remove. Shown as an
    /// in-window overlay (not a Popup) so it stays visible under the topmost, borderless panel.</summary>
    private Border BuildCardMenu(string serial)
    {
        SavedPrinter? Current() => _store.Printers.FirstOrDefault(p => p.Serial == serial);
        var printer = Current();

        var items = new StackPanel();
        var container = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xF7, 0x2C, 0x2C, 0x2E)),
            CornerRadius = new CornerRadius(10),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x2A, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(4),
            MinWidth = 200,
            Child = items
        };
        if (printer is null) return container;

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
            button.Click += (_, _) => { HideCardMenu(); action(); };
            items.Children.Add(button);
        }

        Item(AppSettings.Text("Połącz ponownie", "Reconnect"), () => { if (Current() is { } p) _store.Reconnect(p); });

        var slicers = SlicerLauncher.Installed();
        if (printer.Kind == PrinterKind.Bambu)
        {
            var bambu = slicers.FirstOrDefault(s => s.Name == "Bambu Studio");
            if (bambu is not null)
                Item(AppSettings.Text("Kamera w Bambu Studio", "Camera in Bambu Studio"), () => SlicerLauncher.Open(bambu.Path));
        }
        foreach (var slicer in slicers)
            Item(AppSettings.Text($"Otwórz w {slicer.Name}", $"Open in {slicer.Name}"), () => SlicerLauncher.Open(slicer.Path));

        Item(AppSettings.Text("Kopiuj adres IP", "Copy IP address"), () =>
        {
            if (Current() is { Host.Length: > 0 } p) { try { Clipboard.SetText(p.Host); } catch { } }
        });

        Item(AppSettings.Text("Edytuj drukarkę", "Edit printer"), () =>
        {
            if (Current() is { } p) { new AddPrinterWindow(_store, p) { Owner = this }.ShowDialog(); }
        });
        Item(AppSettings.Text("Usuń drukarkę", "Remove printer"), () =>
        {
            if (Current() is not { } p) return;
            var confirm = MessageBox.Show(this,
                AppSettings.Text($"Usunąć drukarkę {p.Name}?", $"Remove printer {p.Name}?"),
                "BambuBar", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (confirm == MessageBoxResult.Yes) _store.Remove(p);
        });

        return container;
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
