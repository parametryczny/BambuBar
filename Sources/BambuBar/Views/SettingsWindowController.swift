import AppKit
import Combine

@MainActor
final class SettingsWindowController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let githubButton = NSButton()
    private let xButton = NSButton()
    private let languageLabel = NSTextField(labelWithString: "")
    private let appearanceLabel = NSTextField(labelWithString: "")
    private let languageControl = NSSegmentedControl(labels: ["PL", "EN"], trackingMode: .selectOne, target: nil, action: nil)
    private let themeControl = NSSegmentedControl(labels: ["LIGHT", "DARK"], trackingMode: .selectOne, target: nil, action: nil)
    private let launchSwitch = NSSwitch()
    private let launchLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let supportButton = NSButton()
    private let closeButton = NSButton()
    private let notificationsLabel = NSTextField(labelWithString: "")
    private let notifyFinishedCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyErrorCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyPausedCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyLowFilamentCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyHumidityCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var settingsSubscription: AnyCancellable?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        buildInterface()
        refresh()
        settingsSubscription = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }

    func presentCentered() {
        refresh()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        authorLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        authorLabel.textColor = .secondaryLabelColor

        configureProfileButton(githubButton, action: #selector(openGitHub))
        configureProfileButton(xButton, action: #selector(openX))
        let profileRow = NSStackView(views: [githubButton, xButton, NSView()])
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.spacing = 14

        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        languageControl.segmentStyle = .rounded
        languageControl.setWidth(70, forSegment: 0)
        languageControl.setWidth(70, forSegment: 1)

        themeControl.target = self
        themeControl.action = #selector(themeChanged)
        themeControl.segmentStyle = .rounded
        themeControl.setWidth(82, forSegment: 0)
        themeControl.setWidth(82, forSegment: 1)

        launchSwitch.target = self
        launchSwitch.action = #selector(launchAtLoginChanged)
        let launchRow = NSStackView(views: [launchLabel, NSView(), launchSwitch])
        launchRow.orientation = .horizontal
        launchRow.alignment = .centerY

        let form = NSGridView(views: [
            [languageLabel, languageControl],
            [appearanceLabel, themeControl]
        ])
        languageLabel.textColor = .secondaryLabelColor
        appearanceLabel.textColor = .secondaryLabelColor
        form.rowSpacing = 12
        form.columnSpacing = 14
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .leading

        let separator = NSBox()
        separator.boxType = .separator

        versionLabel.textColor = .tertiaryLabelColor
        supportButton.target = self
        supportButton.action = #selector(openSupport)
        supportButton.bezelStyle = .rounded
        supportButton.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Support")
        supportButton.imagePosition = .imageLeading
        closeButton.target = self
        closeButton.action = #selector(closeSettings)
        closeButton.keyEquivalent = "\r"
        let actionRow = NSStackView(views: [versionLabel, NSView(), supportButton, closeButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        notificationsLabel.textColor = .secondaryLabelColor
        let notificationChecks = [notifyFinishedCheck, notifyErrorCheck, notifyPausedCheck, notifyLowFilamentCheck, notifyHumidityCheck]
        for check in notificationChecks {
            check.target = self
            check.action = #selector(notificationToggled)
        }
        let notificationsStack = NSStackView(views: [notificationsLabel] + notificationChecks)
        notificationsStack.orientation = .vertical
        notificationsStack.alignment = .leading
        notificationsStack.spacing = 6

        let stack = NSStackView(views: [titleLabel, authorLabel, profileRow, form, launchRow, notificationsStack, separator, actionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            profileRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            launchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notificationsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func refresh() {
        guard let window else { return }
        let settings = AppSettings.shared
        window.appearance = settings.appearance
        window.title = settings.text("Ustawienia BambuBar", "BambuBar Settings")
        titleLabel.stringValue = settings.text("Ustawienia", "Settings")
        authorLabel.stringValue = "Kamil Grzegorczyk"
        githubButton.title = "@parametryczny on GitHub"
        xButton.title = "@parametryczny on X"
        languageLabel.stringValue = settings.text("Język:", "Language:")
        appearanceLabel.stringValue = settings.text("Wygląd:", "Appearance:")
        languageControl.selectedSegment = settings.language == .pl ? 0 : 1
        themeControl.setLabel(settings.text("JASNY", "LIGHT"), forSegment: 0)
        themeControl.setLabel(settings.text("CIEMNY", "DARK"), forSegment: 1)
        themeControl.selectedSegment = settings.theme == .light ? 0 : 1
        launchLabel.stringValue = settings.text("Uruchamiaj przy logowaniu", "Launch at login")
        launchSwitch.state = LaunchAtLoginManager.isEnabled ? .on : .off
        notificationsLabel.stringValue = settings.text("Powiadomienia:", "Notifications:")
        notifyFinishedCheck.title = settings.text("Druk zakończony", "Print finished")
        notifyErrorCheck.title = settings.text("Błąd drukarki", "Printer error")
        notifyPausedCheck.title = settings.text("Druk wstrzymany", "Print paused")
        notifyLowFilamentCheck.title = settings.text("Niski poziom filamentu", "Low filament")
        notifyHumidityCheck.title = settings.text("Wysoka wilgotność AMS", "High AMS humidity")
        notifyFinishedCheck.state = settings.notifyFinished ? .on : .off
        notifyErrorCheck.state = settings.notifyError ? .on : .off
        notifyPausedCheck.state = settings.notifyPaused ? .on : .off
        notifyLowFilamentCheck.state = settings.notifyLowFilament ? .on : .off
        notifyHumidityCheck.state = settings.notifyHumidity ? .on : .off
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.17"
        versionLabel.stringValue = settings.text("Wersja \(version)", "Version \(version)") + " • \(AccessCodeStore.modeName)"
        supportButton.title = settings.text("Wesprzyj projekt", "Support the project")
        closeButton.title = settings.text("Gotowe", "Done")
    }

    @objc private func languageChanged() {
        AppSettings.shared.language = languageControl.selectedSegment == 0 ? .pl : .en
    }

    @objc private func themeChanged() {
        AppSettings.shared.theme = themeControl.selectedSegment == 0 ? .light : .dark
    }

    @objc private func launchAtLoginChanged() {
        do {
            try LaunchAtLoginManager.setEnabled(launchSwitch.state == .on)
        } catch {
            launchSwitch.state = LaunchAtLoginManager.isEnabled ? .on : .off
            NotificationService.post(title: "BambuBar", body: error.localizedDescription)
        }
    }

    @objc private func notificationToggled() {
        let settings = AppSettings.shared
        settings.notifyFinished = notifyFinishedCheck.state == .on
        settings.notifyError = notifyErrorCheck.state == .on
        settings.notifyPaused = notifyPausedCheck.state == .on
        settings.notifyLowFilament = notifyLowFilamentCheck.state == .on
        settings.notifyHumidity = notifyHumidityCheck.state == .on
    }

    @objc private func openSupport() {
        guard let url = URL(string: "https://suppi.pl/parametryczny") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openGitHub() {
        guard let url = URL(string: "https://github.com/parametryczny") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openX() {
        guard let url = URL(string: "https://x.com/parametryczny") else { return }
        NSWorkspace.shared.open(url)
    }

    private func configureProfileButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .linkColor
    }

    @objc private func closeSettings() {
        close()
    }
}
