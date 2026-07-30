import AppKit
import Combine

@MainActor
final class AddPrinterWindowController: NSWindowController {
    private let store: PrinterStore
    private let printerPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let serialField = NSTextField()
    private let codeField = NSSecureTextField()
    private let pasteCodeButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let scanButton = NSButton(title: "", target: nil, action: nil)
    private let importButton = NSButton(title: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private let detectedLabel = NSTextField(labelWithString: "")
    private let bambuStudioLabel = NSTextField(labelWithString: "Bambu Studio:")
    private let nameLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private let serialLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private var subscription: AnyCancellable?
    private var popupPrinters: [DiscoveredPrinter] = []
    private var editingSerial: String?

    init(store: PrinterStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 385), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppSettings.shared.text("Dodaj drukarkę Bambu Lab", "Add Bambu Lab printer")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshDiscovery() }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        infoLabel.textColor = .secondaryLabelColor

        printerPopup.target = self
        printerPopup.action = #selector(selectedPrinterChanged)
        scanButton.target = self
        scanButton.action = #selector(scan)
        importButton.target = self
        importButton.action = #selector(importFromBambuStudio)
        let discoveryRow = NSStackView(views: [printerPopup, scanButton])
        discoveryRow.orientation = .horizontal
        discoveryRow.spacing = 8
        printerPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pasteCodeButton.target = self
        pasteCodeButton.action = #selector(pasteAccessCode)
        let codeRow = NSStackView(views: [codeField, pasteCodeButton])
        codeRow.orientation = .horizontal
        codeRow.spacing = 8
        codeField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let form = NSGridView(views: [
            [detectedLabel, discoveryRow],
            [bambuStudioLabel, importButton],
            [nameLabel, nameField],
            [hostLabel, hostField],
            [serialLabel, serialField],
            [codeLabel, codeRow]
        ])
        form.rowSpacing = 10
        form.columnSpacing = 12
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill

        statusLabel.textColor = .systemRed
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        saveButton.target = self
        saveButton.action = #selector(savePrinter)
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [titleLabel, infoLabel, form, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            infoLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        localize()
    }

    /// Applies every language-dependent string. Called on each open so the form follows the
    /// current language even though the window is built once and reused.
    private func localize() {
        let settings = AppSettings.shared
        titleLabel.stringValue = editingSerial == nil
            ? settings.text("Dodaj drukarkę", "Add printer")
            : settings.text("Edytuj drukarkę", "Edit printer")
        let storageDescription = AccessCodeStore.usesKeychain
            ? settings.text("Kod zostanie zapisany w pęku kluczy macOS.", "The code is stored in macOS Keychain.")
            : settings.text("Kod zostanie zapisany w lokalnych ustawieniach tego Maca.", "The code is stored in this Mac's local preferences.")
        infoLabel.stringValue = settings.text(
            "Wybierz urządzenie znalezione w Wi‑Fi albo wpisz dane ręcznie. ",
            "Select a device found on Wi-Fi or enter its details manually. "
        ) + storageDescription
        scanButton.title = settings.text("Skanuj ponownie", "Scan again")
        importButton.title = settings.text("Importuj drukarki i kody", "Import printers and codes")
        importButton.toolTip = settings.text(
            "Dopasuj wykryte drukarki i pobierz ich kody z lokalnej konfiguracji Bambu Studio",
            "Match detected printers and load their codes from the local Bambu Studio configuration"
        )
        pasteCodeButton.title = settings.text("Wklej", "Paste")
        pasteCodeButton.toolTip = settings.text("Wklej kod dostępu ze schowka", "Paste access code from clipboard")
        detectedLabel.stringValue = settings.text("Wykryte:", "Detected:")
        nameLabel.stringValue = settings.text("Nazwa:", "Name:")
        hostLabel.stringValue = settings.text("Adres IP:", "IP address:")
        serialLabel.stringValue = settings.text("Numer seryjny:", "Serial number:")
        codeLabel.stringValue = settings.text("Kod dostępu:", "Access code:")
        cancelButton.title = settings.text("Anuluj", "Cancel")
        nameField.placeholderString = settings.text("np. Drukarka w warsztacie", "e.g. Workshop printer")
        hostField.placeholderString = settings.text("np. 192.168.1.50", "e.g. 192.168.1.50")
        serialField.placeholderString = settings.text("Numer seryjny drukarki", "Printer serial number")
        codeField.placeholderString = "PIN / Access Code"
    }

    private func refreshDiscovery() {
        scanButton.isEnabled = !store.isScanning
        // Import reads the Bambu Studio config directly, so it never needs to wait for a scan.
        importButton.isEnabled = editingSerial == nil
        guard editingSerial == nil else { return }
        if store.isScanning {
            statusLabel.stringValue = AppSettings.shared.text("Skanowanie sieci…", "Scanning network…")
            statusLabel.textColor = .secondaryLabelColor
        } else if let message = store.globalMessage {
            statusLabel.stringValue = message
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = ""
            statusLabel.textColor = .systemRed
        }
        let results = store.discovered
        guard results != popupPrinters else { return }
        popupPrinters = results
        printerPopup.removeAllItems()
        if results.isEmpty {
            printerPopup.addItem(withTitle: store.isScanning
                ? AppSettings.shared.text("Szukam drukarek w sieci…", "Searching for printers…")
                : AppSettings.shared.text("Nie znaleziono — wpisz dane ręcznie", "Not found — enter details manually"))
            return
        }
        printerPopup.addItems(withTitles: results.map { "\($0.name) — \($0.host)" })
        printerPopup.selectItem(at: 0)
        fill(with: results[0])
    }

    @objc private func selectedPrinterChanged() {
        let index = printerPopup.indexOfSelectedItem
        guard popupPrinters.indices.contains(index) else { return }
        fill(with: popupPrinters[index])
    }

    private func fill(with printer: DiscoveredPrinter) {
        nameField.stringValue = printer.name
        hostField.stringValue = printer.host
        serialField.stringValue = printer.serial
    }

    @objc private func scan() {
        statusLabel.stringValue = ""
        statusLabel.textColor = .systemRed
        store.scan()
    }

    @objc private func importFromBambuStudio() {
        statusLabel.stringValue = ""
        do {
            let count = try store.importFromBambuStudio()
            let alert = NSAlert()
            alert.messageText = AppSettings.shared.text("Zaimportowano drukarki", "Printers imported")
            alert.informativeText = AppSettings.shared.text(
                "Dodano lub zaktualizowano: \(count). BambuBar będzie używać kodów z lokalnej konfiguracji Bambu Studio.",
                "Added or updated: \(count). BambuBar will use codes from the local Bambu Studio configuration."
            )
            alert.addButton(withTitle: "OK")
            if let window {
                alert.beginSheetModal(for: window) { [weak self] _ in self?.close() }
            }
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func pasteAccessCode() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            statusLabel.stringValue = AppSettings.shared.text("Schowek nie zawiera tekstu.", "The clipboard contains no text.")
            return
        }
        codeField.stringValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.stringValue = ""
        window?.makeFirstResponder(codeField)
    }

    @objc private func savePrinter() {
        statusLabel.stringValue = ""
        do {
            if let editingSerial {
                try store.update(
                    originalSerial: editingSerial,
                    name: nameField.stringValue,
                    serial: serialField.stringValue,
                    host: hostField.stringValue,
                    accessCode: codeField.stringValue
                )
            } else {
                try store.addManually(name: nameField.stringValue, serial: serialField.stringValue, host: hostField.stringValue, accessCode: codeField.stringValue)
            }
            clear()
            close()
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func cancel() { close() }

    func prepareForAdding() {
        let settings = AppSettings.shared
        editingSerial = nil
        localize()
        window?.title = settings.text("Dodaj drukarkę Bambu Lab", "Add Bambu Lab printer")
        saveButton.title = settings.text("Dodaj", "Add")
        codeField.placeholderString = "PIN / Access Code"
        printerPopup.isEnabled = true
        scanButton.isEnabled = true
        importButton.isEnabled = true
        clear()
        popupPrinters = []
        printerPopup.removeAllItems()
        printerPopup.addItem(withTitle: settings.text("Szukam drukarek w sieci…", "Searching for printers…"))
        store.scan()
    }

    func prepareForEditing(_ printer: SavedPrinter) {
        let settings = AppSettings.shared
        editingSerial = printer.serial
        localize()
        window?.title = settings.text("Edytuj drukarkę \(printer.name)", "Edit printer \(printer.name)")
        saveButton.title = settings.text("Zapisz", "Save")
        nameField.stringValue = printer.name
        hostField.stringValue = printer.host
        serialField.stringValue = printer.serial
        codeField.stringValue = ""
        codeField.placeholderString = settings.text("Pozostaw puste, aby zachować obecny kod", "Leave blank to keep the current code")
        statusLabel.stringValue = ""
        statusLabel.textColor = .systemRed
        printerPopup.removeAllItems()
        printerPopup.addItem(withTitle: settings.text("Edycja zapisanej drukarki", "Editing saved printer"))
        printerPopup.isEnabled = false
        scanButton.isEnabled = false
        importButton.isEnabled = false
    }

    private func clear() {
        nameField.stringValue = ""
        hostField.stringValue = ""
        serialField.stringValue = ""
        codeField.stringValue = ""
        statusLabel.stringValue = ""
    }
}
