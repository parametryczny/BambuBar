using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using BambuBar.Services;

namespace BambuBar.UI;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => ApplyModernChrome();
        ApplyLanguage();
        LoadSettings();

        LanguageButton.Click += (_, _) =>
        {
            AppSettings.Polish = !AppSettings.Polish;
            ApplyLanguage();
        };
        StartupCheckBox.Click += (_, _) => LaunchAtLogin.SetEnabled(StartupCheckBox.IsChecked == true);
        PrintFinishedCheckBox.Click += (_, _) => AppSettings.NotifyPrintFinished = PrintFinishedCheckBox.IsChecked == true;
        PrinterErrorCheckBox.Click += (_, _) => AppSettings.NotifyPrinterError = PrinterErrorCheckBox.IsChecked == true;
        PrintPausedCheckBox.Click += (_, _) => AppSettings.NotifyPrintPaused = PrintPausedCheckBox.IsChecked == true;
        LowFilamentCheckBox.Click += (_, _) => AppSettings.NotifyLowFilament = LowFilamentCheckBox.IsChecked == true;
        HighHumidityCheckBox.Click += (_, _) => AppSettings.NotifyHighAmsHumidity = HighHumidityCheckBox.IsChecked == true;
        CheckUpdatesButton.Click += async (_, _) => await CheckUpdatesAsync();
        CloseButton.Click += (_, _) => Close();
    }

    private void ApplyLanguage()
    {
        Title = AppSettings.Text("Ustawienia BambuBar", "BambuBar Settings");
        Heading.Text = AppSettings.Text("Ustawienia", "Settings");

        GeneralHeading.Text = AppSettings.Text("OGÓLNE", "GENERAL");
        LanguageLabel.Text = AppSettings.Text("Język", "Language");
        LanguageButton.Content = AppSettings.Polish ? "Polski" : "English";
        StartupCheckBox.Content = AppSettings.Text("Uruchamiaj z Windows", "Start with Windows");

        NotificationsHeading.Text = AppSettings.Text("POWIADOMIENIA", "NOTIFICATIONS");
        PrintFinishedCheckBox.Content = AppSettings.Text("Druk zakończony", "Print finished");
        PrinterErrorCheckBox.Content = AppSettings.Text("Błąd drukarki", "Printer error");
        PrintPausedCheckBox.Content = AppSettings.Text("Druk wstrzymany", "Print paused");
        LowFilamentCheckBox.Content = AppSettings.Text("Niski poziom filamentu", "Low filament");
        HighHumidityCheckBox.Content = AppSettings.Text("Wysoka wilgotność AMS", "High AMS humidity");

        UpdatesHeading.Text = AppSettings.Text("AKTUALIZACJE", "UPDATES");
        UpdateStatus.Text = AppSettings.Text($"Wersja {UpdateChecker.CurrentVersion}", $"Version {UpdateChecker.CurrentVersion}");
        CheckUpdatesButton.Content = AppSettings.Text("Sprawdź aktualizacje", "Check for updates");

        CloseButton.Content = AppSettings.Text("Zamknij", "Close");
    }

    private void LoadSettings()
    {
        StartupCheckBox.IsChecked = LaunchAtLogin.IsEnabled;
        PrintFinishedCheckBox.IsChecked = AppSettings.NotifyPrintFinished;
        PrinterErrorCheckBox.IsChecked = AppSettings.NotifyPrinterError;
        PrintPausedCheckBox.IsChecked = AppSettings.NotifyPrintPaused;
        LowFilamentCheckBox.IsChecked = AppSettings.NotifyLowFilament;
        HighHumidityCheckBox.IsChecked = AppSettings.NotifyHighAmsHumidity;
    }

    private async Task CheckUpdatesAsync()
    {
        CheckUpdatesButton.IsEnabled = false;
        UpdateStatus.Text = AppSettings.Text("Sprawdzam…", "Checking…");
        try
        {
            var result = await UpdateChecker.LatestAsync();
            if (result is not { } r)
            {
                UpdateStatus.Text = AppSettings.Text("Nie udało się sprawdzić.", "Could not check.");
            }
            else if (r.IsNewer)
            {
                UpdateStatus.Text = AppSettings.Text($"Dostępna wersja {r.Release.Version} — otwieram stronę…",
                                                     $"Version {r.Release.Version} available — opening page…");
                try { Process.Start(new ProcessStartInfo(r.Release.PageUrl) { UseShellExecute = true }); } catch { }
            }
            else
            {
                UpdateStatus.Text = AppSettings.Text($"Masz najnowszą wersję ({UpdateChecker.CurrentVersion}).",
                                                     $"You have the latest version ({UpdateChecker.CurrentVersion}).");
            }
        }
        finally
        {
            CheckUpdatesButton.IsEnabled = true;
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void ApplyModernChrome()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int dark = 1, round = 2, acrylic = 3;
        try
        {
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));    // DWMWA_USE_IMMERSIVE_DARK_MODE
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));   // DWMWA_WINDOW_CORNER_PREFERENCE
            DwmSetWindowAttribute(hwnd, 38, ref acrylic, sizeof(int)); // DWMWA_SYSTEMBACKDROP_TYPE
        }
        catch { /* older Windows — plain window is fine */ }
    }
}
