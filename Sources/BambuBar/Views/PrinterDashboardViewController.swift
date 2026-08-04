import AppKit
import Combine

private let printerCardPasteboardType = NSPasteboard.PasteboardType("pl.bambubar.printer-card")

/// Flipped so a scroll's document anchors its content to the top-left; short content then
/// sits at the top instead of the bottom of the clip view.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class PrinterDashboardViewController: NSViewController {
    private let store: PrinterStore
    private let onAdd: () -> Void
    private let onEdit: (SavedPrinter) -> Void
    private let onReconnect: (SavedPrinter) -> Void
    private let onPreferredContentSize: (NSSize) -> Void
    private let cardsStack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton()
    private let compactButton = NSButton()
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var timerSubscription: AnyCancellable?
    private var cardsBySerial: [String: PrinterCardView] = [:]
    private var compactRowsBySerial: [String: CompactPrinterRowView] = [:]
    private var expandedCardsBySerial: [String: PrinterCardView] = [:]
    private var expandedCompactSerials: Set<String> = []
    private var renderedSerials: [String] = []
    private var renderedCompactMode: Bool?
    private var refreshWorkItem: DispatchWorkItem?
    private let dashboardDefaults = BambuDefaults.shared
    private var prefersCompactMode: Bool
    private var compactModeChosen: Bool

    init(
        store: PrinterStore,
        onAdd: @escaping () -> Void,
        onEdit: @escaping (SavedPrinter) -> Void,
        onReconnect: @escaping (SavedPrinter) -> Void,
        onPreferredContentSize: @escaping (NSSize) -> Void
    ) {
        self.store = store
        self.onAdd = onAdd
        self.onEdit = onEdit
        self.onReconnect = onReconnect
        self.onPreferredContentSize = onPreferredContentSize
        prefersCompactMode = BambuDefaults.shared.bool(forKey: "dashboard-compact-mode")
        compactModeChosen = BambuDefaults.shared.bool(forKey: "dashboard-compact-mode-set")
        super.init(nibName: nil, bundle: nil)
        subscription = store.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh()
        }
        settingsSubscription = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }
        timerSubscription = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshDashboard() }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 480, height: 650))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        view = background

        let title = NSTextField(labelWithString: "BambuBar")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 11, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, summaryLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1

        let addButton = iconButton("plus", tooltip: "Dodaj drukarkę / Add printer", action: #selector(addPressed))
        let refreshButton = iconButton("arrow.clockwise", tooltip: "Połącz ponownie / Reconnect", action: #selector(refreshPressed))
        resetButton.title = "ZRESETUJ"
        resetButton.target = self
        resetButton.action = #selector(resetPressed)
        resetButton.bezelStyle = .recessed
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: 10, weight: .medium)
        resetButton.toolTip = "Usuń zakończone zadania i stare nazwy plików"
        resetButton.cell?.wraps = false
        resetButton.widthAnchor.constraint(equalToConstant: 67).isActive = true
        compactButton.target = self
        compactButton.action = #selector(toggleCompactMode)
        compactButton.bezelStyle = .recessed
        compactButton.controlSize = .small
        compactButton.font = .systemFont(ofSize: 10, weight: .medium)
        compactButton.cell?.wraps = false
        compactButton.widthAnchor.constraint(equalToConstant: 58).isActive = true
        compactButton.isHidden = true
        let header = NSStackView(views: [titleStack, NSView(), compactButton, resetButton, refreshButton, addButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 8
        cardsStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(cardsStack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document

        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            header.heightAnchor.constraint(equalToConstant: 36),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: document.topAnchor),
            cardsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        refreshLocalization()
        refreshDashboard()
    }

    /// Height the popover should take so it fits the printer cards (or compact rows) without
    /// leaving empty space, capped so large fleets scroll instead of growing off-screen.
    private func preferredPopoverHeight(compact: Bool, columns: Int) -> CGFloat {
        let printerCount = store.printers.count
        let insets: CGFloat = 12                 // cardsStack top + bottom edge insets
        let chrome: CGFloat = 12 + 36 + 6 + 8    // view top + header + gap + scroll bottom inset
        var content: CGFloat
        if printerCount == 0 {
            content = 120 + insets
        } else if compact {
            content = CGFloat(printerCount) * 31 + CGFloat(printerCount - 1) * 3 + insets
            content += CGFloat(expandedCompactSerials.count) * (174 + 3)   // full card beneath each expanded row
        } else {
            let rows = Int(ceil(Double(printerCount) / Double(max(1, columns))))
            content = CGFloat(rows) * 174 + CGFloat(max(0, rows - 1)) * 8 + insets
        }
        // Tall enough for up to 8 full cards (2 columns → 4 rows) before scrolling kicks in.
        return min(820, chrome + content)
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refreshDashboard() }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
    }

    private func refreshDashboard() {
        guard isViewLoaded else { return }
        let online = store.telemetry.values.filter { $0.state != .offline }.count
        let settings = AppSettings.shared
        summaryLabel.stringValue = settings.language == .pl
            ? "\(store.printers.count) drukarek • \(online) online"
            : "\(store.printers.count) printers • \(online) online"
        let supportsCompactMode = store.printers.count >= 4
        // Full view fits up to 8 printers; above 8 default to compact. A manual toggle overrides.
        let useCompactMode = supportsCompactMode && (compactModeChosen ? prefersCompactMode : store.printers.count > 8)
        let expandedColumnCount = !useCompactMode && store.printers.count >= 9 ? 3 : 2
        let panelWidth: CGFloat = expandedColumnCount == 3 ? 720 : 480
        onPreferredContentSize(NSSize(
            width: panelWidth,
            height: preferredPopoverHeight(compact: useCompactMode, columns: expandedColumnCount)
        ))
        compactButton.isHidden = !supportsCompactMode
        compactButton.title = settings.text(useCompactMode ? "Rozwiń" : "Zwiń", useCompactMode ? "Expand" : "Collapse")
        compactButton.toolTip = settings.text(
            useCompactMode ? "Pokaż pełne kafelki drukarek" : "Pokaż zwartą listę drukarek",
            useCompactMode ? "Show full printer cards" : "Show compact printer list"
        )
        cardsStack.spacing = useCompactMode ? 3 : 8
        if store.printers.isEmpty {
            detachCardRows()
            cardsBySerial.removeAll()
            compactRowsBySerial.removeAll()
            renderedSerials.removeAll()
            renderedCompactMode = nil
            let empty = NSTextField(wrappingLabelWithString: settings.text(
                "Brak drukarek. Kliknij +, aby wyszukać urządzenia w sieci.",
                "No printers. Click + to find devices on your network."
            ))
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor
            empty.widthAnchor.constraint(equalToConstant: 440).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 120).isActive = true
            cardsStack.addArrangedSubview(empty)
            return
        }

        let desiredSerials = store.printers.map(\.serial)
        // Drop expansion state for printers that no longer exist, so a removed-while-expanded row
        // doesn't keep inflating the popover height.
        expandedCompactSerials.formIntersection(desiredSerials)
        if desiredSerials != renderedSerials || renderedCompactMode != useCompactMode {
            detachCardRows()
            if renderedCompactMode != useCompactMode {
                cardsBySerial.removeAll()
                compactRowsBySerial.removeAll()
                expandedCardsBySerial.removeAll()
            }
            renderedSerials = desiredSerials
            renderedCompactMode = useCompactMode

            if useCompactMode {
                compactRowsBySerial = compactRowsBySerial.filter { desiredSerials.contains($0.key) }
                expandedCardsBySerial = expandedCardsBySerial.filter { desiredSerials.contains($0.key) }
                let contentWidth = panelWidth - 24
                for printer in store.printers {
                    let row = compactRowsBySerial[printer.serial] ?? CompactPrinterRowView(
                        printer: printer,
                        onMove: { [weak self] sourceSerial, targetSerial, insertAfter in
                            self?.store.movePrinter(serial: sourceSerial, relativeTo: targetSerial, insertAfter: insertAfter)
                        },
                        onSelect: { [weak self] in self?.toggleCompactExpansion(printer.serial) }
                    )
                    compactRowsBySerial[printer.serial] = row
                    cardsStack.addArrangedSubview(row)
                    if expandedCompactSerials.contains(printer.serial) {
                        let card = expandedCardsBySerial[printer.serial] ?? makeCard(for: printer)
                        expandedCardsBySerial[printer.serial] = card
                        card.setLayoutWidth(contentWidth)
                        cardsStack.addArrangedSubview(card)
                    }
                }
            } else {
                cardsBySerial = cardsBySerial.filter { desiredSerials.contains($0.key) }
                var cards: [PrinterCardView] = []
                for printer in store.printers {
                    let card = cardsBySerial[printer.serial] ?? makeCard(for: printer)
                    cardsBySerial[printer.serial] = card
                    cards.append(card)
                }
                let contentWidth = panelWidth - 24
                for start in stride(from: 0, to: cards.count, by: expandedColumnCount) {
                    let slice = Array(cards[start..<min(start + expandedColumnCount, cards.count)])
                    let row = NSStackView(views: slice)
                    row.orientation = .horizontal
                    row.alignment = .top
                    row.spacing = 8
                    let cardWidth = (contentWidth - CGFloat(max(0, slice.count - 1)) * row.spacing) / CGFloat(slice.count)
                    slice.forEach { $0.setLayoutWidth(cardWidth) }
                    cardsStack.addArrangedSubview(row)
                }
            }
        }

        for printer in store.printers {
            let telemetry = store.telemetry[printer.serial] ?? .init()
            let message = store.connectionMessages[printer.serial]
            if useCompactMode {
                compactRowsBySerial[printer.serial]?.update(printer: printer, telemetry: telemetry, message: message, settings: settings)
                expandedCardsBySerial[printer.serial]?.update(printer: printer, telemetry: telemetry, message: message, settings: settings)
            } else {
                cardsBySerial[printer.serial]?.update(printer: printer, telemetry: telemetry, message: message, settings: settings)
            }
        }

        // Correct the popover height from the cards' real laid-out size — cards grow when AMS chips
        // wrap onto extra rows, which the fixed per-row estimate above can't anticipate.
        view.layoutSubtreeIfNeeded()
        let measuredContent = cardsStack.fittingSize.height
        if measuredContent > 1 {
            let chromeAndInsets: CGFloat = 12 + 36 + 6 + 8 + 12
            onPreferredContentSize(NSSize(width: panelWidth, height: min(900, chromeAndInsets + measuredContent)))
        }
    }

    private func detachCardRows() {
        for arrangedView in cardsStack.arrangedSubviews {
            if let row = arrangedView as? NSStackView {
                for card in row.arrangedSubviews {
                    row.removeArrangedSubview(card)
                    card.removeFromSuperview()
                }
            }
            cardsStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
    }

    private func settingsChanged() {
        guard isViewLoaded else { return }
        view.appearance = AppSettings.shared.appearance
        view.window?.appearance = AppSettings.shared.appearance
        view.layer?.backgroundColor = NSColor.clear.cgColor
        refreshLocalization()
        refreshDashboard()
    }

    private func refreshLocalization() {
        let settings = AppSettings.shared
        resetButton.title = settings.text("Wyczyść", "Clear")
        resetButton.toolTip = settings.text(
            "Usuń zakończone zadania i stare nazwy plików",
            "Clear completed jobs and old file names"
        )
        let useCompactMode = store.printers.count >= 4 && prefersCompactMode
        compactButton.title = settings.text(useCompactMode ? "Rozwiń" : "Zwiń", useCompactMode ? "Expand" : "Collapse")
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!, target: self, action: action)
        button.bezelStyle = .circular
        button.toolTip = tooltip
        return button
    }

    private func openBambuStudio(camera: Bool) {
        let url = URL(fileURLWithPath: "/Applications/BambuStudio.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let cameraMessage = AppSettings.shared.text(
            "Otwórz kartę Urządzenie, aby zobaczyć kamerę.",
            "Open the Device tab to view the camera."
        )
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in
            if camera {
                NotificationService.post(title: "BambuBar", body: cameraMessage)
            }
        }
    }

    private func copyIP(_ host: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(host, forType: .string)
    }

    private func confirmRemove(_ printer: SavedPrinter) {
        let settings = AppSettings.shared
        let alert = NSAlert()
        alert.messageText = settings.text("Usunąć drukarkę \(printer.name)?", "Remove printer \(printer.name)?")
        alert.informativeText = settings.text(
            "Zapisany kod dostępu i pin certyfikatu tej drukarki zostaną usunięte.",
            "This printer's saved access code and certificate pin will be removed."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: settings.text("Usuń", "Remove"))
        alert.addButton(withTitle: settings.text("Anuluj", "Cancel"))
        // Prefer a modal sheet on the window; fall back to a standalone alert.
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] result in
                if result == .alertFirstButtonReturn { self?.store.remove(printer) }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            store.remove(printer)
        }
    }

    @objc private func addPressed() { onAdd() }
    @objc private func refreshPressed() {
        store.reconnectAll()
        store.refreshPrinterNames()
    }
    @objc private func resetPressed() { store.resetCompletedStatuses() }
    @objc private func toggleCompactMode() {
        guard store.printers.count >= 4 else { return }
        // Toggle relative to what's shown now, and remember that the user made an explicit choice.
        let currentlyCompact = compactModeChosen ? prefersCompactMode : store.printers.count > 8
        prefersCompactMode = !currentlyCompact
        compactModeChosen = true
        dashboardDefaults.set(prefersCompactMode, forKey: "dashboard-compact-mode")
        dashboardDefaults.set(true, forKey: "dashboard-compact-mode-set")
        renderedCompactMode = nil
        refreshDashboard()
    }

    private func makeCard(for printer: SavedPrinter) -> PrinterCardView {
        PrinterCardView(
            printer: printer,
            onEdit: { [weak self] in
                guard let self, let current = self.store.printers.first(where: { $0.serial == printer.serial }) else { return }
                self.onEdit(current)
            },
            onReconnect: { [weak self] in
                guard let self, let current = self.store.printers.first(where: { $0.serial == printer.serial }) else { return }
                self.onReconnect(current)
            },
            onOpenCamera: { [weak self] in self?.openBambuStudio(camera: true) },
            onOpenSlicer: { url in SlicerLauncher.open(url) },
            onCopyIP: { [weak self] in
                guard let self, let host = self.store.printers.first(where: { $0.serial == printer.serial })?.host else { return }
                self.copyIP(host)
            },
            onRemove: { [weak self] in
                guard let self, let current = self.store.printers.first(where: { $0.serial == printer.serial }) else { return }
                self.confirmRemove(current)
            },
            onMove: { [weak self] sourceSerial, targetSerial, insertAfter in
                self?.store.movePrinter(serial: sourceSerial, relativeTo: targetSerial, insertAfter: insertAfter)
            }
        )
    }

    /// Toggles whether one printer's full card is shown beneath its compact row (accordion).
    private func toggleCompactExpansion(_ serial: String) {
        if expandedCompactSerials.contains(serial) { expandedCompactSerials.remove(serial) }
        else { expandedCompactSerials.insert(serial) }
        renderedCompactMode = nil
        refreshDashboard()
    }
}

@MainActor
private final class CompactPrinterRowView: NSGlassEffectView, NSDraggingSource {
    let serial: String
    private let stateIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let dropIndicatorLayer = CALayer()
    private var dragHandle: PrinterDragHandle?
    private let onMove: (_ sourceSerial: String, _ targetSerial: String, _ insertAfter: Bool) -> Void
    private let onSelect: (() -> Void)?

    init(
        printer: SavedPrinter,
        onMove: @escaping (_ sourceSerial: String, _ targetSerial: String, _ insertAfter: Bool) -> Void,
        onSelect: (() -> Void)? = nil
    ) {
        serial = printer.serial
        self.onMove = onMove
        self.onSelect = onSelect
        super.init(frame: .zero)

        style = .regular
        cornerRadius = 10
        tintColor = .clear
        registerForDraggedTypes([printerCardPasteboardType])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked)))
        widthAnchor.constraint(equalToConstant: 456).isActive = true
        heightAnchor.constraint(equalToConstant: 31).isActive = true

        let rowContent = NSView()
        rowContent.wantsLayer = true
        contentView = rowContent

        dropIndicatorLayer.backgroundColor = NSColor.systemBlue.cgColor
        dropIndicatorLayer.cornerRadius = 1
        dropIndicatorLayer.opacity = 0
        dropIndicatorLayer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        rowContent.layer?.addSublayer(dropIndicatorLayer)

        let handle = PrinterDragHandle { [weak self] event in self?.beginRowDrag(with: event) }
        dragHandle = handle
        stateIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        stateIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.widthAnchor.constraint(equalToConstant: 128).isActive = true
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [handle, stateIcon, nameLabel, NSView(), statusLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowContent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rowContent.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: rowContent.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: rowContent.centerYAnchor)
        ])
        update(printer: printer, telemetry: .init(), message: nil, settings: AppSettings.shared)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func rowClicked() { onSelect?() }

    override func layout() {
        super.layout()
        if dropIndicatorLayer.opacity > 0 {
            dropIndicatorLayer.frame.size.width = max(0, bounds.width - 16)
        }
    }

    func update(printer: SavedPrinter, telemetry: PrinterTelemetry, message: String?, settings: AppSettings) {
        nameLabel.stringValue = printer.name
        nameLabel.toolTip = printer.name
        let baseStatus = message ?? settings.activityLabel(stage: telemetry.currentStage, state: telemetry.state)
        if message == nil, telemetry.state == .printing || telemetry.state == .paused {
            statusLabel.stringValue = "\(baseStatus) · \(telemetry.progress)%"
        } else {
            statusLabel.stringValue = baseStatus
        }
        statusLabel.toolTip = statusLabel.stringValue
        let stale = telemetry.lastUpdated.map { Date().timeIntervalSince($0) > 90 } ?? false
        statusLabel.textColor = stale ? .systemOrange : stateColor(telemetry.state)
        stateIcon.image = NSImage(systemSymbolName: telemetry.state.symbol, accessibilityDescription: baseStatus)
        stateIcon.contentTintColor = stateColor(telemetry.state)

        switch telemetry.state {
        case .error:
            tintColor = .systemRed.withAlphaComponent(0.09)
        case .finished:
            tintColor = .systemGreen.withAlphaComponent(0.08)
        default:
            tintColor = .clear
        }
    }

    private func stateColor(_ state: PrinterState) -> NSColor {
        switch state {
        case .printing: .systemBlue
        case .idle, .finished: .systemGreen
        case .paused: .systemOrange
        case .error: .systemRed
        case .offline: .secondaryLabelColor
        }
    }

    private func beginRowDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(serial, forType: printerCardPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let representation = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: representation)
            image.addRepresentation(representation)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragHandle?.reset()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicatorLayer.opacity = 0
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.string(forType: printerCardPasteboardType) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndicatorLayer.opacity = 0 }
        guard let sourceSerial = sender.draggingPasteboard.string(forType: printerCardPasteboardType),
              sourceSerial != serial else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        onMove(sourceSerial, serial, point.y < bounds.midY)
        return true
    }

    private func updateDropIndicator(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let sourceSerial = sender.draggingPasteboard.string(forType: printerCardPasteboardType),
              sourceSerial != serial else {
            dropIndicatorLayer.opacity = 0
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let insertAfter = point.y < bounds.midY
        dropIndicatorLayer.frame = NSRect(
            x: 8,
            y: insertAfter ? 1 : bounds.maxY - 3,
            width: max(0, bounds.width - 16),
            height: 2
        )
        dropIndicatorLayer.opacity = 1
        return .move
    }
}

@MainActor
private final class PrinterCardView: NSGlassEffectView, NSDraggingSource {
    let serial: String
    private let stateEmphasisLayer = CALayer()
    private let dropIndicatorLayer = CALayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let stateDot = NSImageView()
    private let jobLabel = NSTextField(labelWithString: "")
    private let progress = BrutalistProgressView()
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let etaMetric = CompactMetricView(symbol: "clock", tooltip: "ETA")
    private let layerMetric = CompactMetricView(symbol: "square.3.layers.3d", tooltip: "Layer")
    private let nozzleMetric = CompactMetricView(symbol: "thermometer.high", tooltip: "Nozzle")
    private let bedMetric = CompactMetricView(symbol: "rectangle.and.hand.point.up.left", tooltip: "Bed")
    private let chamberMetric = CompactMetricView(symbol: "house", tooltip: "Chamber")
    private let amsLabel = NSTextField(labelWithString: "")
    private let amsChips = WrappingChipsView()
    private var layoutWidthConstraint: NSLayoutConstraint?
    private var dragHandle: PrinterDragHandle?
    private var renderedSlots: [AMSSlot] = []
    private var displayedRemainingMinutes: Int?
    private var etaUpdatedAt: Date?
    private var lastJobName: String?
    private var lastState: PrinterState?
    private var emphasizedState: PrinterState?

    init(
        printer: SavedPrinter,
        onEdit: @escaping () -> Void,
        onReconnect: @escaping () -> Void,
        onOpenCamera: @escaping () -> Void,
        onOpenSlicer: @escaping (URL) -> Void,
        onCopyIP: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onMove: @escaping (_ sourceSerial: String, _ targetSerial: String, _ insertAfter: Bool) -> Void
    ) {
        serial = printer.serial
        super.init(frame: .zero)
        style = .regular
        cornerRadius = 18
        tintColor = NSColor.controlBackgroundColor.withAlphaComponent(0.12)
        let cardContent = NSView()
        cardContent.wantsLayer = true
        stateEmphasisLayer.cornerRadius = 18
        stateEmphasisLayer.opacity = 0
        stateEmphasisLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            "opacity": NSNull()
        ]
        cardContent.layer?.insertSublayer(stateEmphasisLayer, at: 0)
        contentView = cardContent
        registerForDraggedTypes([printerCardPasteboardType])
        // Minimum, not fixed: the card grows when AMS chips wrap onto extra rows (multiple AMS units).
        heightAnchor.constraint(greaterThanOrEqualToConstant: 174).isActive = true

        dropIndicatorLayer.backgroundColor = NSColor.systemBlue.cgColor
        dropIndicatorLayer.cornerRadius = 1.5
        dropIndicatorLayer.opacity = 0
        dropIndicatorLayer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        cardContent.layer?.addSublayer(dropIndicatorLayer)

        stateDot.widthAnchor.constraint(equalToConstant: 15).isActive = true
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail

        var actionEntries: [CardActionsButton.Entry] = [
            .init(polishTitle: "Połącz ponownie", englishTitle: "Reconnect", symbol: "arrow.clockwise", action: onReconnect)
        ]
        // Camera lives in Bambu Studio, so it only makes sense for Bambu printers.
        if printer.kind == .bambu {
            actionEntries.append(.init(polishTitle: "Kamera w Bambu Studio", englishTitle: "Camera in Bambu Studio",
                                       symbol: "video.fill", action: onOpenCamera))
        }
        // Any printer can open a slicer; offer whichever are installed as a submenu.
        let slicers = SlicerLauncher.installed()
        if !slicers.isEmpty {
            let slicerEntries = slicers.map { slicer in
                CardActionsButton.Entry(polishTitle: slicer.name, englishTitle: slicer.name,
                                        symbol: "square.and.arrow.up", action: { onOpenSlicer(slicer.url) })
            }
            actionEntries.append(.init(polishTitle: "Otwórz slicer", englishTitle: "Open slicer",
                                       symbol: "square.and.arrow.up", submenu: slicerEntries))
        }
        actionEntries.append(contentsOf: [
            .init(polishTitle: "Kopiuj adres IP", englishTitle: "Copy IP address", symbol: "doc.on.doc", action: onCopyIP),
            .init(polishTitle: "Edytuj drukarkę", englishTitle: "Edit printer", symbol: "pencil", action: onEdit),
            .init(polishTitle: "Usuń drukarkę", englishTitle: "Remove printer", symbol: "trash", action: onRemove)
        ])
        let actions = CardActionsButton(entries: actionEntries)
        let handle = PrinterDragHandle { [weak self] event in self?.beginCardDrag(with: event) }
        dragHandle = handle
        let header = NSStackView(views: [stateDot, nameLabel, NSView(), handle, actions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7

        jobLabel.font = .systemFont(ofSize: 10, weight: .regular)
        jobLabel.textColor = .secondaryLabelColor
        jobLabel.lineBreakMode = .byTruncatingMiddle
        progress.heightAnchor.constraint(equalToConstant: 13).isActive = true
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        percentLabel.alignment = .right
        percentLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let progressRow = NSStackView(views: [progress, percentLabel])
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 6

        let metricsTop = NSStackView(views: [etaMetric, layerMetric, NSView()])
        metricsTop.orientation = .horizontal
        metricsTop.alignment = .centerY
        metricsTop.spacing = 10
        let metricsBottom = NSStackView(views: [nozzleMetric, bedMetric, chamberMetric, NSView()])
        metricsBottom.orientation = .horizontal
        metricsBottom.alignment = .centerY
        metricsBottom.spacing = 10
        amsLabel.font = .systemFont(ofSize: 9, weight: .medium)
        amsLabel.textColor = .secondaryLabelColor
        amsLabel.alignment = .left
        amsLabel.lineBreakMode = .byTruncatingTail
        amsLabel.widthAnchor.constraint(equalToConstant: 73).isActive = true
        amsChips.wantsLayer = true
        amsChips.layer?.cornerRadius = 8
        amsChips.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        amsChips.setContentHuggingPriority(.defaultLow, for: .horizontal)   // fill the row so chips wrap
        amsChips.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let amsRow = NSStackView(views: [amsLabel, amsChips])
        amsRow.orientation = .horizontal
        amsRow.alignment = .top
        amsRow.spacing = 5

        let stack = NSStackView(views: [header, statusLabel, jobLabel, progressRow, metricsTop, metricsBottom, amsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5

        let content = cardContent
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -11),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -7),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            jobLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            metricsTop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            metricsBottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            amsRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        update(printer: printer, telemetry: .init(), message: nil, settings: AppSettings.shared)
        self.onMove = onMove
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        stateEmphasisLayer.frame = contentView?.bounds ?? bounds
    }

    private var onMove: ((_ sourceSerial: String, _ targetSerial: String, _ insertAfter: Bool) -> Void)?

    func setLayoutWidth(_ width: CGFloat) {
        layoutWidthConstraint?.isActive = false
        layoutWidthConstraint = widthAnchor.constraint(equalToConstant: width)
        layoutWidthConstraint?.isActive = true
    }

    private func beginCardDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(serial, forType: printerCardPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let representation = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: representation)
            image.addRepresentation(representation)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragHandle?.reset()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicatorLayer.opacity = 0
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.string(forType: printerCardPasteboardType) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndicatorLayer.opacity = 0 }
        guard let sourceSerial = sender.draggingPasteboard.string(forType: printerCardPasteboardType),
              sourceSerial != serial else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        onMove?(sourceSerial, serial, point.x >= bounds.midX)
        return true
    }

    private func updateDropIndicator(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let sourceSerial = sender.draggingPasteboard.string(forType: printerCardPasteboardType),
              sourceSerial != serial else {
            dropIndicatorLayer.opacity = 0
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let after = point.x >= bounds.midX
        dropIndicatorLayer.frame = NSRect(x: after ? bounds.maxX - 4 : 1, y: 10, width: 3, height: max(0, bounds.height - 20))
        dropIndicatorLayer.opacity = 1
        return .move
    }

    func update(printer: SavedPrinter, telemetry: PrinterTelemetry, message: String?, settings: AppSettings) {
        nameLabel.stringValue = printer.name
        let dataAge = telemetry.lastUpdated.map { max(0, Date().timeIntervalSince($0)) }
        let stale = dataAge.map { $0 > 90 } ?? false
        let baseStatus = message ?? settings.activityLabel(stage: telemetry.currentStage, state: telemetry.state)
        if let dataAge, dataAge >= 60 {
            statusLabel.stringValue = "\(baseStatus) • \(shortAge(dataAge))"
        } else {
            statusLabel.stringValue = baseStatus
        }
        statusLabel.toolTip = baseStatus
        statusLabel.textColor = stale ? .systemOrange : (message == nil ? stateColor(telemetry.state) : .secondaryLabelColor)
        stateDot.image = NSImage(systemSymbolName: telemetry.state.symbol, accessibilityDescription: telemetry.state.label)
        stateDot.contentTintColor = stateColor(telemetry.state)
        updateCardEmphasis(for: telemetry.state)
        if telemetry.state == .error {
            tintColor = .systemRed.withAlphaComponent(0.065)
        } else if telemetry.state == .finished {
            tintColor = .systemGreen.withAlphaComponent(0.075)
        } else if stale {
            tintColor = .systemOrange.withAlphaComponent(0.045)
        } else {
            tintColor = .clear
        }

        if telemetry.state == .error {
            let errorDescription = HMSResolver.shared.description(for: telemetry.hmsCodes, serial: printer.serial, language: settings.language)
                ?? (telemetry.errorCode != 0
                    ? String(format: settings.text("Kod błędu: 0x%llX", "Error code: 0x%llX"), telemetry.errorCode)
                    : settings.text("Drukarka zgłosiła błąd", "Printer reported an error"))
            jobLabel.stringValue = errorDescription
            jobLabel.toolTip = errorDescription
        } else {
            jobLabel.stringValue = telemetry.jobName?.isEmpty == false
                ? telemetry.jobName!
                : settings.text("BRAK AKTYWNEGO ZADANIA", "NO ACTIVE JOB")
            jobLabel.toolTip = telemetry.jobName
        }
        progress.value = telemetry.progress
        progress.tintColor = stateColor(telemetry.state)
        percentLabel.stringValue = "\(telemetry.progress)%"

        let now = Date()
        let shouldRefreshETA = etaUpdatedAt == nil
            || now.timeIntervalSince(etaUpdatedAt!) >= 300
            || lastJobName != telemetry.jobName
            || lastState != telemetry.state
        if shouldRefreshETA {
            displayedRemainingMinutes = telemetry.remainingMinutes
            etaUpdatedAt = now
        }
        lastJobName = telemetry.jobName
        lastState = telemetry.state
        let eta = displayedRemainingMinutes.map(format) ?? "—"
        let layer = telemetry.currentLayer.flatMap { current in telemetry.totalLayers.map { "\(current)/\($0)" } } ?? "—"
        let nozzle: String
        if let second = telemetry.nozzleTemperature2 {
            // Dual nozzle (H2D): show both current temperatures, e.g. "250°·48°".
            let left = telemetry.nozzleTemperature.map { "\(Int($0.rounded()))°" } ?? "—"
            nozzle = "\(left)·\(Int(second.rounded()))°"
        } else {
            nozzle = temperature(telemetry.nozzleTemperature, telemetry.nozzleTargetTemperature)
        }
        let bed = temperature(telemetry.bedTemperature, telemetry.bedTargetTemperature)
        etaMetric.value = eta
        layerMetric.value = layer
        nozzleMetric.value = nozzle
        bedMetric.value = bed
        chamberMetric.value = telemetry.chamberTemperature.map { "\(Int($0.rounded()))°" } ?? ""
        chamberMetric.isHidden = telemetry.chamberTemperature == nil
        amsLabel.stringValue = amsSummary(telemetry)
        amsLabel.textColor = isHumidityHigh(telemetry.amsHumidity) ? .systemOrange : .secondaryLabelColor

        // Show every slot (all AMS units + external), wrapping onto extra rows when needed.
        let visibleSlots = telemetry.amsSlots
        if renderedSlots != visibleSlots {
            renderedSlots = visibleSlots
            amsChips.isHidden = visibleSlots.isEmpty
            amsChips.setChips(visibleSlots.map { AMSSlotView(slot: $0) })
        }
    }

    private func updateCardEmphasis(for state: PrinterState) {
        guard emphasizedState != state else { return }
        emphasizedState = state
        stateEmphasisLayer.removeAllAnimations()

        switch state {
        case .error:
            stateEmphasisLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.075).cgColor
            stateEmphasisLayer.borderColor = NSColor.systemRed.withAlphaComponent(0.55).cgColor
            stateEmphasisLayer.borderWidth = 1
            stateEmphasisLayer.opacity = 1
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.28
            pulse.toValue = 1.0
            pulse.duration = 1.2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stateEmphasisLayer.add(pulse, forKey: "errorPulse")
        case .finished:
            stateEmphasisLayer.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.045).cgColor
            stateEmphasisLayer.borderColor = NSColor.systemGreen.withAlphaComponent(0.28).cgColor
            stateEmphasisLayer.borderWidth = 1
            stateEmphasisLayer.opacity = 1
        default:
            stateEmphasisLayer.backgroundColor = NSColor.clear.cgColor
            stateEmphasisLayer.borderColor = NSColor.clear.cgColor
            stateEmphasisLayer.borderWidth = 0
            stateEmphasisLayer.opacity = 0
        }
    }

    private func stateColor(_ state: PrinterState) -> NSColor {
        switch state {
        case .printing: .systemBlue
        case .idle, .finished: .systemGreen
        case .paused: .systemOrange
        case .error: .systemRed
        case .offline: .secondaryLabelColor
        }
    }

    private func format(_ minutes: Int) -> String { minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m" }
    private func shortAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }
    private func temperature(_ current: Double?, _ target: Double?) -> String {
        guard let current else { return "—" }
        if let target, target > 0 { return "\(Int(current.rounded()))/\(Int(target.rounded()))°" }
        return "\(Int(current.rounded()))°"
    }
    private func amsSummary(_ telemetry: PrinterTelemetry) -> String {
        guard !telemetry.amsSlots.isEmpty else { return "AMS —" }
        var parts = ["AMS"]
        if let humidity = telemetry.amsHumidity { parts.append("H\(humidity)%") }
        if let temperature = telemetry.amsTemperature { parts.append("\(Int(temperature.rounded()))°") }
        return parts.joined(separator: " ")
    }

    private func isHumidityHigh(_ value: Int?) -> Bool {
        guard let value else { return false }
        return value <= 5 ? value >= 4 : value >= 40
    }
}

@MainActor
private final class PrinterDragHandle: NSImageView {
    private let onDrag: (NSEvent) -> Void
    private var didBeginDrag = false

    init(onDrag: @escaping (NSEvent) -> Void) {
        self.onDrag = onDrag
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Move printer")
        contentTintColor = .tertiaryLabelColor
        toolTip = AppSettings.shared.text("Przeciągnij, aby zmienić kolejność", "Drag to reorder")
        widthAnchor.constraint(equalToConstant: 17).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didBeginDrag else { return }
        didBeginDrag = true
        onDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        didBeginDrag = false
    }

    func reset() {
        didBeginDrag = false
    }
}

@MainActor
private final class CardActionsButton: NSButton {
    struct Entry {
        let polishTitle: String
        let englishTitle: String
        let symbol: String
        let action: (() -> Void)?
        let submenu: [Entry]?

        init(polishTitle: String, englishTitle: String, symbol: String,
             action: (() -> Void)? = nil, submenu: [Entry]? = nil) {
            self.polishTitle = polishTitle
            self.englishTitle = englishTitle
            self.symbol = symbol
            self.action = action
            self.submenu = submenu
        }
    }

    private final class ActionBox {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Actions")
        bezelStyle = .circular
        controlSize = .small
        target = self
        action = #selector(showActions)
        toolTip = AppSettings.shared.text("Więcej działań", "More actions")
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    @objc private func showActions() {
        toolTip = AppSettings.shared.text("Więcej działań", "More actions")
        let menu = buildMenu(from: entries)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.minY), in: self)
    }

    private func buildMenu(from entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            let title = AppSettings.shared.text(entry.polishTitle, entry.englishTitle)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: title)
            if let submenu = entry.submenu {
                item.submenu = buildMenu(from: submenu)
            } else if let action = entry.action {
                item.target = self
                item.action = #selector(performAction(_:))
                item.representedObject = ActionBox(action)
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        (sender.representedObject as? ActionBox)?.run()
    }
}

@MainActor
private final class CompactMetricView: NSView {
    private let valueLabel = NSTextField(labelWithString: "—")
    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    init(symbol: String, tooltip: String) {
        super.init(frame: .zero)
        self.toolTip = tooltip
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        image.contentTintColor = .tertiaryLabelColor
        image.widthAnchor.constraint(equalToConstant: 11).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let stack = NSStackView(views: [image, valueLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class BrutalistProgressView: NSView {
    var value = 0 { didSet { needsDisplay = true } }
    var tintColor: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = bounds.insetBy(dx: 0, dy: 3)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        trackPath.fill()

        let fraction = CGFloat(max(0, min(value, 100))) / 100
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        tintColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3.5, yRadius: 3.5).fill()

        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        let outline = NSBezierPath(roundedRect: track.integral, xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1
        outline.stroke()

        let markerX = min(max(track.minX + track.width * fraction, track.minX + 1), track.maxX - 2)
        let marker = NSRect(x: markerX - 1, y: 0, width: 3, height: bounds.height)
        NSColor.controlBackgroundColor.setFill()
        marker.fill()
        let center = NSRect(x: markerX, y: 0, width: 1, height: bounds.height)
        NSColor.labelColor.setFill()
        center.fill()
    }
}

/// A left-to-right flow layout that wraps its chips onto new rows and reports an intrinsic height
/// derived from its current width — used for the AMS colour dots so many spools (multiple AMS units)
/// wrap onto extra rows instead of overflowing the card.
@MainActor
private final class WrappingChipsView: NSView {
    var horizontalSpacing: CGFloat = 2
    var verticalSpacing: CGFloat = 2
    var contentInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
    private var chips: [NSView] = []
    private var lastLaidOutWidth: CGFloat = -1

    override var isFlipped: Bool { true }

    func setChips(_ views: [NSView]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = views
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastLaidOutWidth) > 0.5 { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        lastLaidOutWidth = bounds.width
        _ = arrange(width: bounds.width, apply: true)
    }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 0 ? bounds.width : 200
        return NSSize(width: NSView.noIntrinsicMetric, height: arrange(width: width, apply: false))
    }

    @discardableResult
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        guard !chips.isEmpty else { return 0 }
        let maxX = width - contentInsets.right
        var x = contentInsets.left
        var y = contentInsets.top
        var rowHeight: CGFloat = 0
        for chip in chips {
            let size = chip.fittingSize
            if x > contentInsets.left, x + size.width > maxX {
                x = contentInsets.left
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            if apply { chip.frame = NSRect(x: x, y: y, width: size.width, height: size.height) }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight + contentInsets.bottom
    }
}

@MainActor
private final class AMSSlotView: NSBox {
    init(slot: AMSSlot) {
        super.init(frame: .zero)
        boxType = .custom
        cornerRadius = 6
        let isEmpty = slot.material == "—"
        let low = (slot.remainingPercent ?? 100) <= 15
        borderWidth = slot.isActive ? 2 : 0.5
        borderColor = slot.isActive ? .systemBlue : .separatorColor
        fillColor = isEmpty
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.16)
            : NSColor(hex: slot.colorHex).withAlphaComponent(0.92)
        contentViewMargins = NSSize(width: 2, height: 1)
        widthAnchor.constraint(equalToConstant: 27).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true

        let title = NSTextField(labelWithString: slot.label)
        title.font = .systemFont(ofSize: 8, weight: .semibold)
        title.alignment = .center
        title.textColor = isEmpty ? .secondaryLabelColor : NSColor(hex: slot.colorHex).contrastingTextColor
        title.toolTip = "\(slot.label) • \(slot.material) • \(slot.remainingPercent.map { "\($0)%" } ?? "—")"
        title.translatesAutoresizingMaskIntoConstraints = false
        contentView!.addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            title.centerYAnchor.constraint(equalTo: contentView!.centerYAnchor)
        ])

        if low {
            let warning = NSView()
            warning.wantsLayer = true
            warning.layer?.backgroundColor = NSColor.systemRed.cgColor
            warning.layer?.cornerRadius = 2.5
            warning.layer?.borderWidth = 1
            warning.layer?.borderColor = NSColor.controlBackgroundColor.cgColor
            warning.translatesAutoresizingMaskIntoConstraints = false
            contentView!.addSubview(warning)
            NSLayoutConstraint.activate([
                warning.widthAnchor.constraint(equalToConstant: 5),
                warning.heightAnchor.constraint(equalToConstant: 5),
                warning.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 1),
                warning.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -1)
            ])
        }
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ClosureButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func clicked() { closure() }
}

private extension NSColor {
    convenience init(hex: String) {
        let clean = String(hex.prefix(6))
        let value = UInt64(clean, radix: 16) ?? 0x808080
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    var contrastingTextColor: NSColor {
        guard let rgb = usingColorSpace(.deviceRGB) else { return .labelColor }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.58 ? .black : .white
    }
}
