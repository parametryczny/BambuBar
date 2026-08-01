# Plan: obsługa drukarek Klipper (Moonraker) + MMU w BambuBar

Cel: dodać drukarki **Klipper** obok Bambu — w oknie dodawania wybór typu, osobny
klient Moonraker, ten sam pulpit i powiadomienia. Dla drukarek z MMU (Voron/ERCF/
Tradrack/Box Turtle przez **Happy Hare**) pokazać sloty tak jak AMS Bambu. Zero
wpływu na obecną obsługę Bambu.

## Zasada architektury

Bambu i Klipper mają wspólny „wtyk": produkują `PrinterTelemetry` i zdarzenia
`connected` / `telemetry` / `disconnected`. Wystarczy **abstrakcja połączenia** —
reszta (karty, powiadomienia, reconnect, ustawienia) działa bez zmian.

## Połączenie z Klipperem (Moonraker)

- REST: `GET http://<host>:<port>/printer/objects/query?extruder&heater_bed&print_stats&virtual_sdcard&display_status&mmu`
- lepiej — WebSocket `ws://<host>:<port>/websocket` (`printer.objects.subscribe`) dla aktualizacji na żywo
- port domyślny **7125**
- auth: zwykle otwarte w LAN; opcjonalnie klucz API (`X-Api-Key`) albo `trusted_clients`
  w `moonraker.conf`. Aplikacja daje **opcjonalne** pole „klucz API".

### Pola przy dodawaniu drukarki Klipper

| Pole | Wymagane | Uwaga |
| --- | --- | --- |
| Adres IP | tak | np. `192.168.1.50` — jedyne konieczne |
| Nazwa | nie | jak puste, dociągnąć z `/printer/info` (hostname) lub użyć IP |
| Port | nie | domyślnie 7125 |
| Klucz API | nie | tylko gdy Moonraker wymusza auth |

Bez access code / numeru seryjnego (to specyfika Bambu).

### Mapowanie statusu → `PrinterTelemetry`

| Moonraker | BambuBar |
| --- | --- |
| `print_stats.state` (printing/paused/complete/error/standby) | `state` |
| `display_status.progress` / `virtual_sdcard.progress` | `progress` |
| `extruder.temperature/target` | dysza |
| `heater_bed.temperature/target` | stół |
| `temperature_sensor chamber`.temperature | komora (jeśli jest) |
| `print_stats.filename` | `jobName` |
| `print_stats.info.current_layer/total_layer` | warstwy |
| `print_duration` + progress (lub metadane slicera) | ETA |
| — | AMS/HMS: nie dotyczy (chyba że MMU, patrz niżej) |

## MMU (Happy Hare) → sloty AMS

Warunek: drukarka używa **Happy Hare** (standard dla ERCF / Tradrack / Box Turtle na
Klipperze). Moonraker udostępnia wtedy obiekt `mmu`.

- Wykrycie: obecność `mmu` z `num_gates > 0` (analogicznie do `device.ctc` = komora).
- Mapowanie `mmu` → `AmsSlot` (per bramka):

| Happy Hare (`mmu`) | AmsSlot |
| --- | --- |
| indeks bramki `0..num_gates-1` | `label` (np. „T0"/„G1") |
| `gate_material[i]` | `material` |
| `gate_color[i]` (hex lub nazwa) | `colorHex` (parser hex/nazwa) |
| `gate == i` | `isActive` |
| `gate_status[i]` (−1/0/1 = nieznany/pusty/jest) | pusty → materiał „—" |
| (brak wagi filamentu) | `remainingPercent = nil` |

- Opcjonalnie: `mmu.action` (loading/unloading/idle) jako etap; `mmu.enabled=false` →
  nie pokazujemy MMU.
- UI dla dużych MMU (9–12 bramek): karta pokazuje 4 sloty → dodać zwijanie/„+N" albo
  skrolowany rządek dla >4.
- Nazwy pól `mmu.*` zweryfikować na realnym `printer/objects/query?mmu` (różnią się
  między wersjami Happy Hare).

## Fazy realizacji

### Faza 0 — model i abstrakcja (fundament)
Pliki: `Models/Printer.swift`, `App/PrinterStore.swift`, nowy `Services/PrinterConnection.swift`
- `enum PrinterKind { bambu, klipper }` (domyślnie `bambu`; migracja: brak w JSON → bambu)
- `SavedPrinter` +pola: `kind`, `port` (7125), `apiKey?`; serial dla Klippera opcjonalny (`id = klipper-<host>`)
- protokół `PrinterConnection { start(); stop() }` + wspólne zdarzenie; `MQTTClient` go spełnia
- `PrinterStore.reconnect` → `switch kind` → `MQTTClient` albo `MoonrakerClient`

### Faza 1 — klient + parser
Pliki: nowe `Services/MoonrakerClient.swift`, `Services/MoonrakerStatusParser.swift`
- MVP: polling REST co ~2 s (+ opcjonalny `X-Api-Key`); `connected/telemetry/disconnected`
- parser `result.status` → `PrinterTelemetry`
- Faza 1.5 (później): WebSocket na żywo

### Faza 1.6 — MMU / Happy Hare → sloty AMS
Pliki: `Services/MoonrakerStatusParser.swift`
- dołączyć `mmu` do zapytania; mapowanie jak w sekcji „MMU" powyżej

### Faza 2 — UI (dodawanie/edycja/karta)
Pliki: `Views/AddPrinterWindowController.swift`, `Views/PrinterDashboardViewController.swift`
- segmented control „Bambu / Klipper"; dla Klippera pola IP/nazwa/port/klucz API + „Testuj połączenie"
- `PrinterStore.addKlipper(name:host:port:apiKey:)`
- karta: ukryj AMS gdy brak MMU; plakietka „Klipper"; obsługa >4 slotów dla dużych MMU

### Faza 3 — storage
- nowe pola `SavedPrinter` serializują się same; klucz API jak kody Bambu (Keychain/DPAPI); brak cert-pinningu (HTTP)

### Faza 4 — wykrywanie (opcjonalne)
- mDNS `_moonraker._tcp` / `_octoprint._tcp`; MVP: ręczne dodawanie

### Faza 5 — parytet Windows (i ewentualnie Linux)
- mirror `MoonrakerClient`/parsera/UI do C# (`HttpClient` + `System.Text.Json`)
- Linux: rozważyć Avalonia na współdzielonym Services (tray = StatusNotifierItem;
  na GNOME wymaga rozszerzenia AppIndicator); DPAPI → Secret Service; pakowanie AppImage/Flatpak

### Faza 6 — testy i polish
- `Tests/…/MoonrakerStatusParserTests` (status + `mmu`) na realnym `printer/objects/query`
- powiadomienia działają automatycznie (ten sam `notifyChanges`); „Sprawdź aktualizacje" bez zmian
- CHANGELOG + README (nowy typ drukarki)

## Kolejność (przyrostowo)
1. Faza 0 + 1 (model + MoonrakerClient polling + parser) — działa „w tle"
2. Faza 1.6 (MMU) — sloty AMS dla Voron/ERCF z Happy Hare
3. Faza 2 (UI) — widoczne dla użytkownika
4. Faza 3 (storage)
5. Faza 5 (Windows / Linux)
6. Faza 1.5 / 4 / 6 (WebSocket, mDNS, testy)

## Decyzje / ryzyka
- polling vs WebSocket: MVP polling, WS później
- auth: opcjonalny klucz API; README o `trusted_clients`
- różne nazwy sensorów/pól MMU między konfiguracjami/wersjami → parser defensywny, weryfikacja na realnych danych
- ETA: MVP z progress+elapsed; dokładniejsza z metadanych slicera później
- duże MMU (9–12 bramek) → potrzebna zmiana w prezentacji slotów
