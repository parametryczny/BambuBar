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
            DiscoverySection.Visibility = Visibility.Collapsed;
            NameBox.Text = editing.Name;
            HostBox.Text = editing.Host;
            SerialBox.Text = editing.Serial;
            CodeBox.Text = "";
        }

        ScanButton.Click += (_, _) => _store.Scan();
        ImportButton.Click += (_, _) => ImportFromStudio();
        SaveButton.Click += (_, _) => Save();
        CancelButton.Click += (_, _) => Close();
        DetectedList.SelectionChanged += OnDetectedSelected;

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
        CancelButton.Content = AppSettings.Text("Anuluj", "Cancel");
        SaveButton.Content = _editing is null ? AppSettings.Text("Dodaj", "Add") : AppSettings.Text("Zapisz", "Save");
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
            if (_editing is not null)
                _store.Update(_editing.Serial, NameBox.Text, SerialBox.Text, HostBox.Text, CodeBox.Text);
            else
                _store.AddManually(NameBox.Text, SerialBox.Text, HostBox.Text, CodeBox.Text);
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
