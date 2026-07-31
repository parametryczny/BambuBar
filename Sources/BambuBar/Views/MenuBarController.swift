import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: PrinterStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var addWindow: AddPrinterWindowController?
    private var settingsWindow: SettingsWindowController?
    private var notificationObserver: Any?

    init(store: PrinterStore) {
        self.store = store
        super.init()

        let dashboard = PrinterDashboardViewController(
            store: store,
            onAdd: { [weak self] in self?.showAddPrinter() },
            onEdit: { [weak self] printer in self?.showEditPrinter(printer) },
            onReconnect: { [weak store] printer in store?.reconnect(printer) },
            onPreferredContentSize: { [weak self] size in
                guard let self, self.popover.contentSize != size else { return }
                self.popover.contentSize = size
            }
        )
        popover.contentSize = NSSize(width: 480, height: 650)
        popover.contentViewController = dashboard
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = AppSettings.shared.appearance
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        settingsSubscription = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.appearance = AppSettings.shared.appearance
                self?.popover.contentViewController?.view.appearance = AppSettings.shared.appearance
                self?.updateStatusItem()
            }
        }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .bambuBarShowDashboard, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.showDashboard() }
        }
    }

    func showDashboard() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.appearance = AppSettings.shared.appearance
        popover.contentViewController?.view.appearance = AppSettings.shared.appearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        button.attributedTitle = NSAttributedString(
            string: "BL",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold),
                .foregroundColor: NSColor.white,
                .shadow: shadow
            ]
        )
        button.toolTip = store.activePrintCount > 0
            ? AppSettings.shared.text("BambuBar — drukuje: \(store.activePrintCount)", "BambuBar — printing: \(store.activePrintCount)")
            : "BambuBar"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            if popover.isShown { closePopover() }
            showContextMenu(relativeTo: button)
            return
        }
        if popover.isShown {
            closePopover()
        } else {
            popover.appearance = AppSettings.shared.appearance
            popover.contentViewController?.view.appearance = AppSettings.shared.appearance
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitor()
        }
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        let settings = AppSettings.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        let showPanel = NSMenuItem(
            title: settings.text("Pokaż drukarki", "Show printers"),
            action: #selector(showPopoverFromMenu),
            keyEquivalent: ""
        )
        showPanel.target = self
        showPanel.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: showPanel.title)
        menu.addItem(showPanel)

        let settingsItem = NSMenuItem(
            title: settings.text("Ustawienia…", "Settings…"),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: settingsItem.title)
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: settings.text("Zakończ BambuBar", "Quit BambuBar"),
            action: #selector(quitApplication),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 3), in: button)
    }

    @objc private func showPopoverFromMenu() {
        guard let button = statusItem.button else { return }
        popover.appearance = AppSettings.shared.appearance
        popover.contentViewController?.view.appearance = AppSettings.shared.appearance
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installOutsideClickMonitor()
    }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.presentCentered()
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closePopover() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    private func showAddPrinter() {
        popover.performClose(nil)
        if addWindow == nil { addWindow = AddPrinterWindowController(store: store) }
        addWindow?.prepareForAdding()
        addWindow?.showWindow(nil)
        addWindow?.window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showEditPrinter(_ printer: SavedPrinter) {
        popover.performClose(nil)
        if addWindow == nil { addWindow = AddPrinterWindowController(store: store) }
        addWindow?.prepareForEditing(printer)
        addWindow?.showWindow(nil)
        addWindow?.window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
