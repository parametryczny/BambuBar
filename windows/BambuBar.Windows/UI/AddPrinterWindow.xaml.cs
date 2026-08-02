using System.Windows;
using System.Windows.Controls;
using BambuBar.Models;
using BambuBar.Services;

namespace BambuBar.UI;

public partial class AddPrinterWindow : Window
{
    private readonly PrinterStore _store;
    private readonly SavedPrinter? _editing;

    public AddPrinterWindow(PrinterStore store, SavedPrinter? editing = null)
    {
        InitializeComponent();
        _store = store;
        _editing = editing;

        Localize();

        if (editing is not null)
        {
            NameBox.Text = editing.Name;
            HostBox.Text = editing.Host;
            SerialBox.Text = editing.Serial;
            CodeBox.Text = "";
            // The printer kind cannot change once added; lock the selector to the saved type.
            TypeSection.Visibility = Visibility.Collapsed;
            if (editing.Kind == PrinterKind.Klipper)
            {
                KlipperRadio.IsChecked = true;
                PortBox.Text = editing.Port?.ToString() ?? "";
                ApiKeyBox.Text = editing.ApiKey ?? "";
            }
            // The tray-pin checkbox is offered only when editing a saved printer (its serial is known).
            ProgressCheck.Visibility = Visibility.Visible;
            ProgressCheck.IsChecked = TrayProgressPreference.IsEnabled(editing.Serial);
        }

        BambuRadio.Checked += (_, _) => ApplyKind();
        KlipperRadio.Checked += (_, _) => ApplyKind();
        ScanButton.Click += (_, _) => _store.Scan();
        ImportButton.Click += (_, _) => ImportFromStudio();
        SaveButton.Click += (_, _) => Save();
        CancelButton.Click += (_, _) => Close();
        DetectedList.SelectionChanged += OnDetectedSelected;
        ApplyKind();

        _store.Updated += OnStoreUpdated;
        Closed += (_, _) => _store.Updated -= OnStoreUpdated;
        RefreshDetected();
    }

    private void Localize()
    {
        Title = _editing is null ? AppSettings.Text("Dodaj drukarkę", "Add printer") : AppSettings.Text("Edytuj drukarkę", "Edit printer");
        Heading.Text = Title;
        DetectedLabel.Text = AppSettings.Text("Wykryte drukarki", "Detected printers");
        ImportButton.Content = AppSettings.Text("Importuj z Bambu Studio", "Import from Bambu Studio");
        NameLabel.Text = AppSettings.Text("Nazwa (opcjonalnie)", "Name (optional)");
        HostLabel.Text = AppSettings.Text("Adres IP", "IP address");
        SerialLabel.Text = AppSettings.Text("Numer seryjny", "Serial number");
        CodeLabel.Text = AppSettings.Text("Kod dostępu (Access Code / PIN)", "Access Code / PIN");
        BambuRadio.Content = AppSettings.Text("Bambu Lab", "Bambu Lab");
        KlipperRadio.Content = AppSettings.Text("Klipper (Moonraker)", "Klipper (Moonraker)");
        PortLabel.Text = AppSettings.Text("Port Moonraker (domyślnie 7125)", "Moonraker port (default 7125)");
        ApiKeyLabel.Text = AppSettings.Text("Klucz API (opcjonalnie)", "API key (optional)");
        CancelButton.Content = AppSettings.Text("Anuluj", "Cancel");
        SaveButton.Content = _editing is null ? AppSettings.Text("Dodaj", "Add") : AppSettings.Text("Zapisz", "Save");
        ProgressCheck.Content = AppSettings.Text("Pokaż postęp tej drukarki w zasobniku",
                                                 "Show this printer's progress in the tray");
    }

    private bool IsKlipper => KlipperRadio.IsChecked == true;

    /// <summary>Shows only the fields relevant to the selected printer kind. Klipper needs a host,
    /// an optional port and API key; Bambu needs discovery, serial and access code.</summary>
    private void ApplyKind()
    {
        bool klipper = IsKlipper;
        DiscoverySection.Visibility = (klipper || _editing is not null) ? Visibility.Collapsed : Visibility.Visible;
        SerialLabel.Visibility = SerialBox.Visibility = klipper ? Visibility.Collapsed : Visibility.Visible;
        CodeLabel.Visibility = CodeBox.Visibility = klipper ? Visibility.Collapsed : Visibility.Visible;
        PortLabel.Visibility = PortBox.Visibility = klipper ? Visibility.Visible : Visibility.Collapsed;
        ApiKeyLabel.Visibility = ApiKeyBox.Visibility = klipper ? Visibility.Visible : Visibility.Collapsed;
        HostLabel.Text = klipper
            ? AppSettings.Text("Adres IP / nazwa hosta", "IP address / host name")
            : AppSettings.Text("Adres IP", "IP address");
    }

    private void OnStoreUpdated(object? sender, EventArgs e) => Dispatcher.Invoke(RefreshDetected);

    private void RefreshDetected()
    {
        if (_editing is not null) return;
        var selectedSerial = (DetectedList.SelectedItem as DiscoveredItem)?.Printer.Serial;
        DetectedList.Items.Clear();
        foreach (var d in _store.Discovered)
            DetectedList.Items.Add(new DiscoveredItem(d));
        DetectedLabel.Text = _store.IsScanning
            ? AppSettings.Text("Skanowanie…", "Scanning…")
            : AppSettings.Text($"Wykryte drukarki ({_store.Discovered.Count})", $"Detected printers ({_store.Discovered.Count})");
        if (selectedSerial is not null)
            foreach (DiscoveredItem item in DetectedList.Items)
                if (item.Printer.Serial == selectedSerial) { DetectedList.SelectedItem = item; break; }
    }

    private void OnDetectedSelected(object? sender, SelectionChangedEventArgs e)
    {
        if (DetectedList.SelectedItem is DiscoveredItem item)
        {
            NameBox.Text = item.Printer.Name;
            HostBox.Text = item.Printer.Host;
            SerialBox.Text = item.Printer.Serial;
            CodeBox.Focus();
        }
    }

    private void ImportFromStudio()
    {
        try
        {
            int count = _store.ImportFromBambuStudio();
            MessageBox.Show(this, AppSettings.Text($"Zaimportowano drukarek: {count}", $"Imported printers: {count}"), "BambuBar");
            Close();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private void Save()
    {
        try
        {
            if (IsKlipper)
            {
                int? port = null;
                var portText = PortBox.Text.Trim();
                if (portText.Length > 0)
                {
                    if (!int.TryParse(portText, out var parsed) || parsed <= 0 || parsed > 65535)
                        throw new ArgumentException(AppSettings.Text("Nieprawidłowy port.", "Invalid port."));
                    port = parsed;
                }
                // Editing may change the host, which changes the derived serial; drop the old entry first.
                if (_editing is not null && _editing.Host != HostBox.Text.Trim())
                    _store.Remove(_editing);
                _store.AddKlipper(NameBox.Text, HostBox.Text, port, ApiKeyBox.Text);
            }
            else if (_editing is not null)
                _store.Update(_editing.Serial, NameBox.Text, SerialBox.Text, HostBox.Text, CodeBox.Text);
            else
                _store.AddManually(NameBox.Text, SerialBox.Text, HostBox.Text, CodeBox.Text);

            // The tray-pin checkbox is only shown when editing, so the final serial is known here.
            if (_editing is not null)
            {
                var finalSerial = IsKlipper ? $"klipper-{HostBox.Text.Trim()}" : SerialBox.Text.Trim();
                TrayProgressPreference.SetEnabled(ProgressCheck.IsChecked == true, finalSerial);
            }
            Close();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }

    private sealed class DiscoveredItem
    {
        public DiscoveredPrinter Printer { get; }
        public DiscoveredItem(DiscoveredPrinter printer) => Printer = printer;
        public override string ToString() => $"{Printer.Name}  —  {Printer.Host}  ({Printer.Serial})";
    }
}
