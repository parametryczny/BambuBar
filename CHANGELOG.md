# Historia zmian BambuBar

Wszystkie istotne zmiany w aplikacji BambuBar są opisane w tym pliku.

## 0.1.19 — 2026-08-01

- powiadomienia macOS są teraz natywne: mają własną ikonę BambuBar, a kliknięcie otwiera pulpit aplikacji zamiast Edytora skryptów
- w ustawieniach macOS można wybrać, które powiadomienia mają się pojawiać (druk zakończony, błąd drukarki, druk wstrzymany, niski poziom filamentu, wysoka wilgotność AMS)
- okno pulpitu dopasowuje wysokość do liczby drukarek — przy 1–3 drukarkach nie ma już pustej przestrzeni, a przy dużej flocie pojawia się przewijanie
- dodano przycisk „Sprawdź aktualizacje" w ustawieniach macOS, który pobiera i instaluje nowszą wersję oraz uruchamia aplikację ponownie
- AMS i kolory pozostają widoczne przez cały czas druku (wcześniej znikały przy cząstkowych aktualizacjach statusu, m.in. na A1 mini z AMS lite)
- temperatura komory jest pokazywana wyłącznie dla drukarek z rzeczywistym czujnikiem (X1, X2, P2), a ukrywana tam, gdzie go nie ma (A1, A1 mini, P1) — wykrywane bezpośrednio z telemetrii drukarki

### Windows

- dodano okno ustawień z wyborem, które powiadomienia mają się pojawiać (druk zakończony, błąd, wstrzymany, niski poziom filamentu, wysoka wilgotność AMS) oraz przełącznikami języka i autostartu
- AMS pozostaje widoczny przez cały czas druku — ta sama poprawka cząstkowych aktualizacji statusu co w macOS
- temperatura komory jest odczytywana z tego samego pola telemetrii co w macOS, więc rozpoznanie obecności czujnika działa spójnie na obu platformach
- import z Bambu Studio obsługuje formaty JSON (z końcową sumą kontrolną) i starszy INI, także gdy Bambu Studio pozostaje otwarte, oraz wyszukuje konfigurację w kilku lokalizacjach

## 0.1.18 — 2026-07-30

- dodano pierwszą wersję beta BambuBar dla 64-bitowego Windows 10 i 11, działającą jako aplikacja w zasobniku systemowym
- wersja Windows jest publikowana jako samodzielny `BambuBar.exe` w archiwum ZIP i nie wymaga osobnej instalacji środowiska .NET
- dodano instalator `BambuBar-Setup-Windows-x64.exe`, który nie wymaga uprawnień administratora, uruchamia aplikację po instalacji, dodaje skrót w menu Start oraz automatyczny start przy logowaniu do Windows
- przeniesiono na Windows najważniejsze funkcje wersji macOS: wykrywanie drukarek, lokalne połączenie MQTT przez TLS, statusy druku, AMS/HMS, powiadomienia oraz import z Bambu Studio
- kody dostępu w wersji Windows są szyfrowane dla bieżącego użytkownika za pomocą Windows DPAPI
- poprawiono import konfiguracji Bambu Studio na Windows — obsługiwane są formaty JSON z końcową sumą kontrolną i starszy INI, również gdy Bambu Studio pozostaje otwarte
- wersja Windows pozostaje betą i nie jest jeszcze podpisana certyfikatem; wymaga dalszych testów interfejsu, zasobnika, zapory oraz wykrywania drukarek na fizycznych komputerach z Windows
- dodano usuwanie drukarki z menu „⋯" na karcie (z potwierdzeniem)
- skanowanie sieci kończy się w kilka sekund zamiast ~30 s (nie poddaje się już po 8 s)
- import z Bambu Studio działa na czystej instalacji — czyta adres IP z konfiguracji i tworzy drukarki bez potrzeby skanu, a przycisk importu nie czeka już na skanowanie
- wykrywanie SSDP działa również przy uruchomionym Bambu Studio (rezerwowy port, gdy 2021 jest zajęty)
- okno dodawania i edycji drukarki jest w pełni tłumaczone przy każdym otwarciu
- dodano testy jednostkowe (kodek MQTT, parser SSDP, parser statusu) oraz skrypt `scripts/run-tests.sh`
- ustabilizowano podpis aplikacji, dzięki czemu zgoda macOS na dostęp do sieci lokalnej przetrwa kolejne przebudowy
- README dostępne w wersji polskiej i angielskiej

## 0.1.14 — 2026-07-30

- opublikowano kompletny kod źródłowy projektu na licencji MIT
- import z Bambu Studio odbywa się wyłącznie po świadomym kliknięciu przycisku przez użytkownika
- zaimportowane kody dostępu są zapisywane w pęku kluczy macOS i nie wymagają ponownego odczytu konfiguracji Bambu Studio przy starcie
- dodano dokumentację bezpieczeństwa, zasady współtworzenia i automatyczny build dla macOS 26
- dodano informacje o autorze oraz odnośniki do profili GitHub, X i strony wsparcia
- wyeliminowano wielokrotne pytania pęku kluczy podczas automatycznego ponownego łączenia
- ujednolicono lokalną tożsamość podpisu dla aplikacji i uruchamiania przez plik `.command`

## 0.1.13 — 2026-07-29

- wydano pierwszą kompletną wersję natywnego monitora drukarek Bambu Lab dla paska menu macOS
- dodano wykrywanie drukarek w sieci lokalnej, ręczne dodawanie urządzeń oraz automatyczne ponowne łączenie
- dodano status wydruku, procent postępu, pozostały czas, warstwy oraz temperatury dyszy, stołu i komory
- dodano szczegółowe etapy pracy, m.in. bazowanie, nagrzewanie, poziomowanie, ładowanie i zmianę filamentu
- dodano komunikaty HMS, powiadomienia o błędach i zakończeniu druku oraz subtelne wyróżnienie kafelków błędu i zakończonego zadania
- dodano obsługę AMS na cztery szpule i pojedynczego AMS wraz z kolorami, aktywnym slotem, wilgotnością, temperaturą i ostrzeżeniami o niskim poziomie filamentu
- dodano obsługę polskich znaków w nazwach plików oraz czytelne skrócone informacje AMS
- dodano przeciąganie kafelków, zapisywanie kolejności drukarek i znacznik miejsca upuszczenia
- widok rozwinięty korzysta z dwóch kolumn, a od dziewięciu drukarek automatycznie przechodzi na trzy kolumny
- od czterech drukarek dostępny jest tryb zwarty, mieszczący do piętnastu statusów w wąskim panelu
- wybrany układ, język polski lub angielski oraz jasny lub ciemny wygląd są zapamiętywane
- ustawienia otwierają się w osobnym oknie z menu kontekstowego ikony `BL` i zawierają opcję uruchamiania przy logowaniu oraz odnośnik do wsparcia
- ograniczono odświeżanie ETA do pięciu minut, ukryto licznik świeżych danych i dodano ostrzeżenie o nieaktualnej telemetrii
- kody dostępu są bezpiecznie przechowywane w pęku kluczy macOS, a komunikacja z drukarkami odbywa się lokalnie bez konta Bambu Cloud
