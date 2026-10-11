import AppKit
import Foundation

private let appName = "ClamAV Installer"
private let home = FileManager.default.homeDirectoryForCurrentUser
private let base = home.appendingPathComponent(".clamav-automatik")
private let logs = home.appendingPathComponent("Library/Logs/ClamAV-Automatik")
private let accent = NSColor(srgbRed: 0.10, green: 0.43, blue: 0.37, alpha: 1)

final class Card: NSView {
    let stack = NSStackView()
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor(white: 0.87, alpha: 1).cgColor
        layer?.borderWidth = 1
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusLabel = NSTextField(labelWithString: tr("Bereit zur Einrichtung"))
    var resultLabel = NSTextField(wrappingLabelWithString: tr("Noch kein Scan mit dieser Einrichtung abgeschlossen."))
    var footerLabel = NSTextField(labelWithString: tr("Alle Schritte finden auf diesem Mac statt."))
    var spinner = NSProgressIndicator()
    var progressStack = NSStackView()
    var progressBar = NSProgressIndicator()
    var progressLabel = NSTextField(wrappingLabelWithString: "")
    var activityLabel = NSTextField(wrappingLabelWithString: "")
    var latestMessageLabel = NSTextField(wrappingLabelWithString: "")
    var progressHint = NSTextField(wrappingLabelWithString: "")
    var console = NSTextView()
    var logScroll = NSScrollView()
    var passwordField = NSSecureTextField()
    var passwordButton: NSButton!
    var returnButton: NSButton!
    var yesButton: NSButton!
    var noButton: NSButton!
    var cancelButton: NSButton!
    var installButton: NSButton!
    var testButton: NSButton!
    var uninstallButton: NSButton!
    var legacyUninstallButton: NSButton!
    var legacyNotice: NSTextField!
    var languagePopup: NSPopUpButton!
    var inputStack = NSStackView()
    var detailButton: NSButton!
    var interactiveButtons: [NSButton] = []
    var process: Process?
    var stdinHandle: FileHandle?
    var rawOutput = Data()
    var secrets: [String] = []
    var secureInputAllowed = false
    var wasCancelled = false
    var monitoring = false
    var scanPanelVisible = false
    var scanJobRunning: Bool?
    var scanJobCheckAt = Date.distantPast
    var scanJobCheckPending = false
    var lastScanAtRequest = ""
    var monitorStarted: Date?
    var timer: Timer?
    var operationStarted: Date?
    var lastOutputAt: Date?
    var setupOperation = false
    var currentStage = ""
    var stageTitle = ""
    var promptState = InputPromptState()
    var waitingForReturn: Bool { promptState.kind == .returnKey }
    var waitingForYesNo: Bool { promptState.kind == .yesNo }
    var streamReadFailed = false
    let preview = CommandLine.arguments.contains("--preview")

    var managed: Bool {
        (try? String(contentsOf: base.appendingPathComponent(".owner"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) == "ClamAV-Automatik-managed-v1"
    }
    var installed: Bool { managed && FileManager.default.fileExists(atPath: base.appendingPathComponent("bin/clamav-automatik.sh").path) }
    var packagePresent: Bool {
        // Presence only enables a confirmed action; the backend checks use,
        // dependencies and exact package paths again before any changes.
        let fm = FileManager.default
        let rack = "/opt/homebrew/Cellar/clamav"
        if let entries = try? fm.contentsOfDirectory(atPath: rack), !entries.isEmpty { return true }
        return fm.fileExists(atPath: "/opt/homebrew/opt/clamav") ||
            (try? fm.destinationOfSymbolicLink(atPath: "/opt/homebrew/opt/clamav")) != nil
    }
    var legacyPresent: Bool {
        let candidates = [".local/bin/clamav-daily-scan.sh",
                          "Library/LaunchAgents/ch.ivan.clamav.dailyscan.plist",
                          "Library/LaunchAgents/ch.ivan.clamav.freshclam.plist",
                          "Library/LaunchAgents/sh.brew.clamav.plist"]
        // Presence only enables a reviewable action. The backend validates
        // ownership, all job arguments and loaded sources before any change.
        return candidates.contains { (try? home.appendingPathComponent($0).resourceValues(forKeys: [.isSymbolicLinkKey])) != nil }
    }
    var busy: Bool { process != nil }

    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
               color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: tr(text))
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let b = NSButton(title: tr(title), target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.font = .systemFont(ofSize: 13, weight: .medium)
        if primary { b.bezelColor = accent; b.contentTintColor = .white }
        return b
    }
    func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let v = NSStackView(views: views)
        v.orientation = .horizontal; v.alignment = .centerY; v.spacing = spacing
        return v
    }
    func addFull(_ child: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    func makeCard(_ number: String, _ title: String, _ body: String, _ buttons: [NSButton]) -> Card {
        let card = Card()
        let n = label(number, size: 12, weight: .bold, color: accent)
        n.widthAnchor.constraint(equalToConstant: 22).isActive = true
        card.stack.addArrangedSubview(row([n, label(title, size: 17, weight: .semibold, color: .labelColor)]))
        addFull(label(body), to: card.stack)
        card.stack.addArrangedSubview(row(buttons))
        return card
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.setActivationPolicy(.regular)
        createMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 940),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = preview ? tr("ClamAV Installer – Vorschau") : appName
        window.minSize = NSSize(width: 940, height: 730)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(white: 0.96, alpha: 1)
        let root = NSView()
        window.contentView = root

        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.17, blue: 0.20, alpha: 1).cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 212)
        ])
        let rail = NSStackView()
        rail.orientation = .vertical; rail.alignment = .leading; rail.spacing = 15
        rail.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(rail)
        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 35),
            rail.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            rail.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20)
        ])
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "ClamAV")
        icon.contentTintColor = NSColor(srgbRed: 0.47, green: 0.87, blue: 0.71, alpha: 1)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 54).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 62).isActive = true
        rail.addArrangedSubview(icon)
        rail.addArrangedSubview(label("ClamAV", size: 27, weight: .bold, color: .white))
        rail.addArrangedSubview(label(tr("AUTOMATIK"), size: 11, weight: .semibold, color: NSColor(white: 0.66, alpha: 1)))
        let spacer = NSView(); spacer.heightAnchor.constraint(equalToConstant: 16).isActive = true
        rail.addArrangedSubview(spacer)
        for text in [tr("01   Einrichten"), tr("02   Zugriff erlauben"), tr("03   Scan testen"), tr("04   Deinstallieren")] {
            rail.addArrangedSubview(label(text, size: 13, weight: .medium, color: NSColor(white: 0.92, alpha: 1)))
        }
        let railInfo = label(tr("Apple Silicon\nmacOS · Version 1.0\n\nTäglich um 19:00 Uhr\nSignaturen alle 2 Stunden"), size: 11, color: NSColor(white: 0.68, alpha: 1))
        railInfo.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(railInfo)
        NSLayoutConstraint.activate([
            railInfo.leadingAnchor.constraint(equalTo: rail.leadingAnchor),
            railInfo.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            railInfo.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -26)
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -22)
        ])
        languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (code, name) in AppLanguage.choices {
            languagePopup.addItem(withTitle: name)
            languagePopup.lastItem?.representedObject = code
        }
        languagePopup.selectItem(at: AppLanguage.choices.firstIndex(where: { $0.0 == AppLanguage.shared.code }) ?? 0)
        languagePopup.target = self; languagePopup.action = #selector(changeLanguage(_:))
        languagePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(row([label(tr("Sprache"), size: 12), languagePopup]))
        stack.addArrangedSubview(label(tr("ClamAV einrichten"), size: 29, weight: .bold, color: .labelColor))
        addFull(label(tr("Automatische Scans für Downloads, Schreibtisch und Dokumente.")), to: stack)
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = accent
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        stack.addArrangedSubview(row([spinner, statusLabel]))

        progressStack.orientation = .vertical; progressStack.alignment = .leading; progressStack.spacing = 7
        progressLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        progressBar.style = .bar; progressBar.isIndeterminate = false
        progressBar.minValue = 0; progressBar.maxValue = 100
        activityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        activityLabel.textColor = .secondaryLabelColor
        latestMessageLabel.font = .systemFont(ofSize: 12)
        latestMessageLabel.maximumNumberOfLines = 3
        progressHint.font = .systemFont(ofSize: 11)
        progressHint.textColor = .secondaryLabelColor
        for view in [progressLabel, progressBar, activityLabel, latestMessageLabel, progressHint] as [NSView] {
            addFull(view, to: progressStack)
        }
        progressStack.isHidden = true
        addFull(progressStack, to: stack)

        installButton = button(tr("Installieren / aktualisieren"), #selector(install), primary: true)
        let statusButton = button(tr("Status prüfen"), #selector(checkStatus))
        interactiveButtons += [installButton, statusButton]
        let c1 = makeCard("01", tr("Installation & Updates"), tr("Homebrew bei Bedarf automatisch einrichten und ClamAV auf die neueste stabile Homebrew-Version bringen."), [installButton, statusButton])
        addFull(c1, to: stack)

        let settings = button(tr("Einstellungen öffnen"), #selector(openPrivacy))
        let guidance = button(tr("Freigabe-Anleitung"), #selector(showFDA))
        let c2 = makeCard("02", tr("Festplattenvollzugriff"), tr("Diese macOS-Freigabe musst du einmal selbst erteilen. Die App kann sie nicht automatisch aktivieren."), [settings, guidance])
        addFull(c2, to: stack)

        testButton = button(tr("Neustarten & Scan testen"), #selector(testScan), primary: true)
        interactiveButtons.append(testButton)
        let logsButton = button(tr("Logs öffnen"), #selector(openLogs))
        let c3 = makeCard("03", tr("Automatik testen"), tr("Nach der Freigabe den Scanner neu starten und einen echten Hintergrundscan auslösen."), [testButton, logsButton])
        resultLabel.font = .systemFont(ofSize: 12)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.isSelectable = true
        addFull(resultLabel, to: c3.stack)
        addFull(c3, to: stack)

        uninstallButton = button(tr("Deinstallieren…"), #selector(uninstall))
        interactiveButtons.append(uninstallButton)
        let c4 = makeCard("04", tr("Deinstallation"), tr("Neue und bisherige ClamAV-Einrichtungen verwalten. Vor dem Entfernen zeigt die App, welche Daten erhalten bleiben."), [uninstallButton])
        legacyNotice = label(tr("Bisherige Einrichtung gefunden. Zum Wechseln zuerst „Bisherige Einrichtung entfernen…“ verwenden."), size: 12, color: .systemOrange)
        addFull(legacyNotice, to: c4.stack)
        legacyUninstallButton = button(tr("Bisherige Einrichtung entfernen…"), #selector(uninstallLegacy))
        interactiveButtons.append(legacyUninstallButton)
        c4.stack.addArrangedSubview(legacyUninstallButton)
        addFull(c4, to: stack)

        let details = Card()
        detailButton = button(tr("Protokoll anzeigen"), #selector(toggleDetails))
        cancelButton = button(tr("Vorgang abbrechen"), #selector(cancelOperation))
        cancelButton.isEnabled = false
        details.stack.addArrangedSubview(row([detailButton]))
        logScroll.hasVerticalScroller = true; logScroll.hasHorizontalScroller = false
        logScroll.borderType = .noBorder
        logScroll.documentView = console
        console.isEditable = false; console.isSelectable = true
        console.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        console.textColor = .labelColor; console.backgroundColor = NSColor(white: 0.975, alpha: 1)
        console.textContainerInset = NSSize(width: 8, height: 8)
        console.isHorizontallyResizable = false; console.isVerticallyResizable = true
        console.autoresizingMask = [.width]
        console.textContainer?.widthTracksTextView = true
        logScroll.heightAnchor.constraint(equalToConstant: 145).isActive = true
        addFull(logScroll, to: details.stack)
        logScroll.isHidden = true

        inputStack.orientation = .vertical; inputStack.alignment = .leading; inputStack.spacing = 7
        addFull(label(tr("Bei einer Rückfrage die passende Antwort wählen: Ja oder Nein, Return bestätigen oder das Passwort eingeben, sobald das Feld freigegeben ist."), size: 11), to: inputStack)
        passwordField.placeholderString = tr("Administrator-Passwort")
        passwordField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        passwordField.target = self; passwordField.action = #selector(sendPassword)
        passwordField.isEnabled = false
        passwordButton = button(tr("Passwort senden"), #selector(sendPassword))
        passwordButton.isEnabled = false
        returnButton = button(tr("Return / Weiter"), #selector(sendReturn))
        yesButton = button(tr("Ja"), #selector(sendYes))
        noButton = button(tr("Nein"), #selector(sendNo))
        yesButton.isEnabled = false; noButton.isEnabled = false
        inputStack.addArrangedSubview(row([yesButton, noButton]))
        inputStack.addArrangedSubview(row([passwordField, passwordButton, returnButton]))
        addFull(inputStack, to: progressStack)
        progressStack.addArrangedSubview(cancelButton)
        inputStack.isHidden = true
        addFull(details, to: stack)
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footerLabel)

        refreshLocalState()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshLocalState(); self?.refreshActivity()
        }
        window.center()
        if let screen = NSScreen.main, window.frame.height > screen.visibleFrame.height {
            window.setFrame(NSRect(x: window.frame.minX, y: screen.visibleFrame.minY,
                                   width: window.frame.width, height: screen.visibleFrame.height), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func changeLanguage(_ sender: NSPopUpButton) {
        guard !busy, let code = sender.selectedItem?.representedObject as? String else { return }
        AppLanguage.shared.select(code)
        let previousWindow = window
        let previousFrame = window.frame
        timer?.invalidate()
        statusLabel = NSTextField(labelWithString: tr("Bereit zur Einrichtung"))
        resultLabel = NSTextField(wrappingLabelWithString: tr("Noch kein Scan mit dieser Einrichtung abgeschlossen."))
        footerLabel = NSTextField(labelWithString: tr("Alle Schritte finden auf diesem Mac statt."))
        spinner = NSProgressIndicator(); console = NSTextView(); logScroll = NSScrollView()
        progressStack = NSStackView(); progressBar = NSProgressIndicator()
        progressLabel = NSTextField(wrappingLabelWithString: ""); activityLabel = NSTextField(wrappingLabelWithString: "")
        latestMessageLabel = NSTextField(wrappingLabelWithString: ""); progressHint = NSTextField(wrappingLabelWithString: "")
        passwordField = NSSecureTextField(); inputStack = NSStackView()
        interactiveButtons.removeAll()
        applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        window.setFrame(previousFrame, display: true)
        addOutput(Data())
        previousWindow?.delegate = nil
        previousWindow?.close()
    }

    func createMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Über ClamAV Installer"), action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("ClamAV Installer beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; main.addItem(app)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: tr("Bearbeiten"))
        editMenu.addItem(withTitle: tr("Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tr("Einfügen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: tr("Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; main.addItem(edit)
        let tools = NSMenuItem(); let toolsMenu = NSMenu(title: tr("Werkzeuge"))
        let parallel = NSMenuItem(title: tr("Getrennte Zusatzinstallation…"), action: #selector(parallelInstall), keyEquivalent: "")
        parallel.target = self; toolsMenu.addItem(parallel)
        let quarantine = NSMenuItem(title: tr("Quarantäne im Finder"), action: #selector(openQuarantine), keyEquivalent: "")
        quarantine.target = self; toolsMenu.addItem(quarantine)
        let manual = NSMenuItem(title: tr("Vollständige Anleitung"), action: #selector(openManual), keyEquivalent: "")
        manual.target = self; toolsMenu.addItem(manual)
        tools.submenu = toolsMenu; main.addItem(tools)
        NSApp.mainMenu = main
    }

    func resource(_ name: String) -> URL { Bundle.main.resourceURL!.appendingPathComponent(name) }
    func runtimeScript() -> URL {
        installed ? base.appendingPathComponent("bin/clamav-automatik.sh") : resource("install.sh")
    }
    func setBusy(_ value: Bool) {
        interactiveButtons.forEach { $0.isEnabled = !value }
        testButton.isEnabled = !value && (installed || preview)
        uninstallButton.isEnabled = !value && (managed || packagePresent || preview)
        legacyUninstallButton.isEnabled = !value && (legacyPresent || preview)
        languagePopup.isEnabled = !value
        cancelButton.isEnabled = value
        inputStack.isHidden = true
        returnButton.isEnabled = false
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if !value { promptState.reset(); setSecureInput(false); yesButton.isEnabled = false; noButton.isEnabled = false }
    }
    func setSecureInput(_ allowed: Bool) {
        secureInputAllowed = allowed && busy
        passwordField.isEnabled = secureInputAllowed
        passwordButton.isEnabled = secureInputAllowed
        if !secureInputAllowed { passwordField.stringValue = "" }
        refreshActivity()
    }
    func refreshActivity() {
        guard busy, let started = operationStarted else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(started)))
        let quiet = max(0, Int(Date().timeIntervalSince(lastOutputAt ?? started)))
        let duration = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        activityLabel.stringValue = tr("Laufzeit {elapsed} · Letzte Meldung vor {seconds} s", ["elapsed": duration, "seconds": String(quiet)])
        if wasCancelled || streamReadFailed {
            statusLabel.stringValue = tr("Vorgang wird beendet …")
            inputStack.isHidden = true
            yesButton.isEnabled = false; noButton.isEnabled = false
            returnButton.isEnabled = false
            passwordField.isEnabled = false; passwordButton.isEnabled = false
            return
        }
        statusLabel.stringValue = waitingForYesNo ? tr("Bestätigung benötigt · Ja oder Nein wählen") :
            (waitingForReturn ? tr("Bestätigung benötigt · Return / Weiter anklicken") :
            (secureInputAllowed ? tr("Administrator-Passwort benötigt") : stageTitle))
        statusLabel.textColor = waitingForYesNo || waitingForReturn || secureInputAllowed ? .systemOrange : accent
        inputStack.isHidden = !(waitingForYesNo || waitingForReturn || secureInputAllowed)
        yesButton.isEnabled = waitingForYesNo; noButton.isEnabled = waitingForYesNo
        yesButton.isHidden = !waitingForYesNo; noButton.isHidden = !waitingForYesNo
        returnButton.isEnabled = waitingForReturn
        passwordField.isEnabled = secureInputAllowed && !waitingForReturn && !waitingForYesNo
        passwordButton.isEnabled = secureInputAllowed && !waitingForReturn && !waitingForYesNo
        if quiet >= 30 && !waitingForReturn && !waitingForYesNo && !secureInputAllowed {
            progressHint.stringValue = tr("Seit {seconds} s keine neue Meldung. Der Vorgang kann weiterhin arbeiten; bitte Rückfragen und Protokoll prüfen.", ["seconds": String(quiet)])
            progressHint.textColor = .systemOrange
        } else {
            progressHint.stringValue = setupOperation ? tr("Fortschritt nach Einrichtungsschritten; keine Zeitprognose.") : ""
            progressHint.textColor = .secondaryLabelColor
        }
    }
    func showStage(_ key: String) {
        let stages: [String: (Int, String)] = [
            "checking": (1, tr("Voraussetzungen werden geprüft …")),
            "homebrew_check": (2, tr("Homebrew wird geprüft …")),
            "homebrew_install": (2, tr("Homebrew wird installiert …")),
            "homebrew_update": (3, tr("Homebrew-Paketdaten werden aktualisiert …")),
            "clamav_install": (4, tr("Neueste ClamAV-Version wird installiert …")),
            "clamav_upgrade": (4, tr("ClamAV wird aktualisiert …")),
            "clamav_verify": (5, tr("ClamAV-Version wird geprüft …")),
            "configuration": (6, tr("Einstellungen und Scan-Aufgaben werden vorbereitet …")),
            "signatures": (7, tr("Virensignaturen werden aktualisiert …")),
            "jobs": (8, tr("Hintergrundjobs werden eingerichtet …")),
            "uninstall_check": (0, tr("Deinstallation wird geprüft …")),
            "uninstall_stop": (0, tr("Hintergrundjobs werden beendet …")),
            "uninstall_archive": (0, tr("Daten werden archiviert …")),
            "package_archive": (0, tr("Paketreste werden geprüft und sicher archiviert …")),
            "package_remove": (0, tr("ClamAV-Paket wird entfernt …")),
            "package_repair": (0, tr("Geschützte ClamAV-Ordner werden repariert …"))
        ]
        guard key != currentStage, let (step, title) = stages[key] else { return }
        currentStage = key; stageTitle = title
        if setupOperation && step > 0 {
            let percent = (step - 1) * 100 / 8
            progressBar.doubleValue = Double(percent)
            progressLabel.stringValue = tr("{percent} % · Schritt {step} von {total}", ["percent": String(percent), "step": String(step), "total": "8"])
        } else { progressLabel.stringValue = title }
    }
    func showDetails() {
        logScroll.isHidden = false; detailButton.title = tr("Protokoll ausblenden")
    }
    func addOutput(_ data: Data, fromProcess: Bool = true) {
        if fromProcess && !data.isEmpty {
            lastOutputAt = Date()
            if busy { promptState.append(data) }
        }
        rawOutput.append(data)
        if rawOutput.count > 1_000_000 { rawOutput.removeFirst(rawOutput.count - 800_000) }
        var text = String(decoding: rawOutput, as: UTF8.self)
        text = text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for secret in secrets where !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "••••••••") }
        if busy, let stage = text.components(separatedBy: .newlines).last(where: { $0.hasPrefix("@@CLAMAV:STAGE:") }) {
            let key = String(stage.dropFirst("@@CLAMAV:STAGE:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            showStage(key)
        }
        console.string = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("@@CLAMAV:") }.joined(separator: "\n")
        if fromProcess, busy, let latest = console.string.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            latestMessageLabel.stringValue = String(latest.prefix(300))
        }
        console.scrollToEndOfDocument(nil)
        refreshActivity()
    }
    func addMessage(_ text: String) { addOutput(Data((text + "\n").utf8), fromProcess: false) }
    func controlLine(_ line: String) {
        if line == "CLAMAV_PTY_ECHO=0" { setSecureInput(true) }
        else if line == "CLAMAV_PTY_ECHO=1" { setSecureInput(false) }
        else if line == "CLAMAV_PTY_INPUT_REJECTED" {
            promptState.reset()
            setSecureInput(false)
            addMessage(tr("Die Eingabe wurde nicht gesendet: Die Rückfrage ist nicht mehr aktiv. Bitte die aktuelle Meldung prüfen."))
        } else if !line.isEmpty { addMessage(line) }
    }
    func streamFailed(for child: Process) {
        guard process === child, !streamReadFailed else { return }
        streamReadFailed = true
        promptState.reset()
        setSecureInput(false)
        addMessage(tr("Ausgabe konnte nicht gelesen werden. Der Vorgang wird sicher beendet."))
        if child.isRunning { child.terminate() }
    }

    func run(_ option: String, installing: Bool = false, heading: String,
             completion: ((Int32, String) -> Void)? = nil) {
        guard !busy else { return }
        cancelButton.isHidden = false; progressBar.isHidden = false
        scanPanelVisible = false
        wasCancelled = false
        streamReadFailed = false
        operationStarted = Date(); lastOutputAt = nil
        setupOperation = option == "--install" || option == "--allow-parallel"
        currentStage = ""; stageTitle = tr(heading); promptState.reset()
        progressStack.isHidden = false
        progressBar.isIndeterminate = !setupOperation
        progressBar.doubleValue = 0
        if !setupOperation { progressBar.startAnimation(nil) }
        progressLabel.stringValue = setupOperation ? tr("{percent} % · Schritt {step} von {total}", ["percent": "0", "step": "1", "total": "8"]) : tr(heading)
        latestMessageLabel.stringValue = tr("Warte auf die erste Meldung …")
        progressHint.stringValue = tr("Die Schritte können unterschiedlich lange dauern. Downloads und Signaturprüfungen benötigen manchmal mehrere Minuten.")
        footerLabel.textColor = .secondaryLabelColor
        rawOutput.removeAll(keepingCapacity: false)
        secrets.removeAll(keepingCapacity: false)
        console.string = ""
        statusLabel.stringValue = tr(heading)
        statusLabel.textColor = accent
        showDetails()
        addMessage("\n— \(heading) —")
        let p = Process()
        p.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pty-bridge")
        if preview {
            let fixture = "printf 'GUI-Test: keine Installation.\\n'; stty -echo; printf 'Password: '; IFS= read -r answer; stty echo; printf '\\nEingabe verdeckt empfangen.\\n'; exit 0"
            p.arguments = ["--gui-input", "/bin/bash", "-c", fixture]
        } else {
            p.arguments = ["--gui-input", "/bin/bash", (installing ? resource("install.sh") : runtimeScript()).path, option]
        }
        p.currentDirectoryURL = home
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["TERM"] = "dumb"
        env.removeValue(forKey: "BASH_ENV"); env.removeValue(forKey: "ENV")
        env.removeValue(forKey: "NONINTERACTIVE")
        env["INTERACTIVE"] = "1"
        env["CLAMAV_LANGUAGE"] = AppLanguage.shared.code
        // A cancelled service operation may need to wait for launchd before
        // restoring jobs; allow the backend's bounded rollback to finish.
        env["CLAMAV_PTY_TERMINATION_GRACE_SECONDS"] = "120"
        p.environment = env
        let input = Pipe(), output = Pipe(), control = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = control
        do { try p.run() } catch {
            progressBar.stopAnimation(nil)
            statusLabel.stringValue = tr("Vorgang konnte nicht gestartet werden")
            statusLabel.textColor = .systemRed
            addMessage(error.localizedDescription)
            completion?(2, error.localizedDescription)
            return
        }
        process = p; stdinHandle = input.fileHandleForWriting
        setBusy(true)
        refreshActivity()
        let controlReader = DispatchGroup()
        controlReader.enter()
        DispatchQueue(label: "clamav.gui.control").async { [weak self] in
            defer { controlReader.leave() }
            var pending = Data()
            do {
                while let data = try LivePipeReader.readChunk(from: control.fileHandleForReading) {
                    pending.append(data)
                    while let index = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<index], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        pending.removeSubrange(...index)
                        DispatchQueue.main.async {
                            guard self?.process === p else { return }
                            self?.controlLine(line)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.streamFailed(for: p) }
            }
        }
        DispatchQueue(label: "clamav.gui.output").async { [weak self] in
            var transcript = Data()
            do {
                while let data = try LivePipeReader.readChunk(from: output.fileHandleForReading) {
                    transcript.append(data)
                    if transcript.count > 1_000_000 { transcript.removeFirst(transcript.count - 800_000) }
                    DispatchQueue.main.async {
                        guard self?.process === p else { return }
                        self?.addOutput(data)
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.streamFailed(for: p) }
            }
            p.waitUntilExit()
            controlReader.wait()
            let code = p.terminationStatus
            let text = String(decoding: transcript, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self = self else { return }
                try? self.stdinHandle?.close()
                self.stdinHandle = nil; self.process = nil
                self.setBusy(false)
                self.progressBar.stopAnimation(nil)
                let resultCode: Int32 = self.streamReadFailed ? 2 : code
                if self.setupOperation && resultCode == 0 && !self.wasCancelled && text.contains("@@CLAMAV:RESULT:INSTALLED") {
                    self.progressBar.doubleValue = 100
                    self.progressLabel.stringValue = tr("100 % · Einrichtung abgeschlossen")
                }
                self.rawOutput = Data(self.console.string.utf8)
                self.secrets.removeAll(keepingCapacity: false)
                self.statusLabel.stringValue = self.wasCancelled ? tr("Vorgang abgebrochen") : (resultCode == 0 ? tr("Vorgang abgeschlossen") : tr("Vorgang braucht Aufmerksamkeit"))
                self.statusLabel.textColor = resultCode == 0 && !self.wasCancelled ? accent : .systemOrange
                self.refreshLocalState()
                completion?(resultCode, text)
            }
        }
    }

    @objc func install() {
        guard !busy else { return }
        run("--install", installing: true, heading: tr("ClamAV wird eingerichtet …")) { [weak self] code, text in
            guard let self = self else { return }
            if code == 0 && !self.wasCancelled {
                self.statusLabel.stringValue = self.preview ? tr("Vorschautest abgeschlossen") : tr("Eingerichtet · Festplattenvollzugriff noch prüfen")
                self.footerLabel.stringValue = tr("Weiter mit Schritt 02: Freigabe in den Systemeinstellungen.")
            } else if text.contains("Vorhandene ClamAV-Jobs") {
                self.alert(tr("Vorhandene ClamAV-Einrichtung erkannt"), tr("Die bestehende Einrichtung wurde nicht verändert. Die Details stehen im Protokoll. Wenn du bewusst eine zusätzliche, getrennte Einrichtung möchtest, wähle Werkzeuge → Getrennte Zusatzinstallation."))
            } else if !self.wasCancelled {
                self.alert(tr("Einrichtung nicht abgeschlossen"), tr("Bitte den letzten Hinweis im Protokoll prüfen. Bei einem laufenden Scan oder Update nach dessen Abschluss erneut versuchen. Bereits vorhandene Daten bleiben erhalten."))
            }
        }
    }
    @objc func parallelInstall() {
        guard !busy else { return }
        let a = NSAlert()
        a.messageText = tr("Zusätzliche ClamAV-Einrichtung?")
        a.informativeText = tr("Bestehende fremde Jobs bleiben aktiv. Eine getrennte Einrichtung kann doppelte Scans, zusätzliche Downloads und höheren Speicherverbrauch verursachen.")
        a.addButton(withTitle: tr("Abbrechen")); a.addButton(withTitle: tr("Zusätzlich installieren"))
        a.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn {
                self?.run("--allow-parallel", installing: true, heading: tr("Getrennte Einrichtung wird installiert …")) { code, _ in
                    if code == 0 && self?.wasCancelled == false { self?.statusLabel.stringValue = tr("Eingerichtet · Festplattenvollzugriff noch prüfen") }
                }
            }
        }
    }
    @objc func checkStatus() {
        if !installed && legacyPresent && !preview {
            run("--legacy-status", installing: true, heading: tr("Bisherige Einrichtung prüfen"))
            return
        }
        if !installed && !preview {
            alert(tr("Noch nicht eingerichtet"), tr("Diese App hat noch keine eigene ClamAV-Automatik gefunden. Eine andere vorhandene ClamAV-Installation bleibt davon unabhängig."))
            return
        }
        run("--status", heading: tr("Status wird geprüft …")) { [weak self] code, text in
            guard let self = self else { return }
            guard !self.wasCancelled else { return }
            if code == 0 && (text.contains("@@CLAMAV:DAEMON:READY") || text.contains("clamd: erreichbar")) {
                self.statusLabel.stringValue = tr("Scanner erreichbar · letztes Scanergebnis unten")
            } else if self.preview {
                self.statusLabel.stringValue = tr("Vorschautest abgeschlossen")
            } else {
                self.statusLabel.stringValue = tr("Scanner nicht erreichbar oder Status unvollständig")
                self.statusLabel.textColor = .systemOrange
            }
        }
    }
    @objc func uninstall() {
        guard !busy else { return }
        if !managed && !preview { uninstallPackageRemainder(); return }
        let a = NSAlert()
        a.messageText = tr("ClamAV-Automatik deinstallieren?")
        a.informativeText = tr("Die eigenen Hintergrundjobs werden entfernt. Quarantäne, Einstellungen und Signaturen werden in einem eigenen Archiv aufbewahrt. Logs und Homebrew bleiben erhalten.")
        let removePackage = NSButton(checkboxWithTitle: tr("ClamAV-Paket ebenfalls entfernen"), target: nil, action: nil)
        removePackage.state = .off
        let accessory = NSStackView(views: [removePackage, label(tr("Das ClamAV-Paket kann von anderen Programmen genutzt werden. Bei erkannten fremden Jobs oder Abhängigkeiten wird die Paketentfernung verweigert."), size: 11)])
        accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 460, height: 88)
        accessory.widthAnchor.constraint(equalToConstant: 460).isActive = true
        for child in accessory.arrangedSubviews { child.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true }
        a.accessoryView = accessory
        a.addButton(withTitle: tr("Abbrechen")); a.addButton(withTitle: tr("Deinstallieren"))
        a.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self = self else { return }
            let option = removePackage.state == .on ? "--uninstall-package" : "--uninstall"
            self.monitoring = false
            self.run(option, installing: true, heading: tr("ClamAV wird deinstalliert …")) { code, text in
                guard !self.wasCancelled else { return }
                if code == 0 && text.contains("@@CLAMAV:RESULT:UNINSTALLED") {
                    self.statusLabel.stringValue = tr("Automatik entfernt · Daten bleiben erhalten")
                    let prefix = "@@CLAMAV:ARCHIVE:"
                    if let line = text.components(separatedBy: .newlines).last(where: { $0.hasPrefix(prefix) }) {
                        let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        self.finishUninstall(tr("Die Automatik wurde entfernt. Aufbewahrte Daten: {path}", ["path": path]))
                    } else {
                        self.finishUninstall(tr("Automatik entfernt · Daten bleiben erhalten"))
                    }
                } else if code == 0 && text.contains("@@CLAMAV:RESULT:NOT_INSTALLED") {
                    self.statusLabel.stringValue = tr("Es wurde keine eigene Installation gefunden.")
                    self.finishUninstall(tr("Es wurde keine eigene Installation gefunden."))
                } else if text.contains("@@CLAMAV:RESULT:PARTIAL_UNINSTALL") {
                    self.showPartialUninstall(text)
                } else if self.preview && code == 0 {
                    self.statusLabel.stringValue = tr("Vorschautest abgeschlossen")
                } else {
                    self.alert(tr("Deinstallation nicht abgeschlossen"), tr("Bitte das Protokoll prüfen. Bereits archivierte Daten bleiben erhalten."))
                }
            }
        }
    }
    func showPartialUninstall(_ output: String) {
        statusLabel.stringValue = tr("Automatik entfernt · Paketentfernung offen")
        statusLabel.textColor = .systemOrange
        var summary = tr("Die Automatik ist bereits entfernt. Das ClamAV-Paket konnte noch nicht vollständig entfernt werden. Deine Archive, Quarantäne und Logs bleiben erhalten.\n\nWähle „ClamAV-Paket entfernen…“, um die Paketentfernung zu wiederholen. Bei geschützten Homebrew-Ordnern fragt die App nach deinem Administrator-Passwort.")
        let prefix = "@@CLAMAV:ARCHIVE:"
        if let line = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix(prefix) }) {
            let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            summary += "\n\n" + tr("Die Automatik wurde entfernt. Aufbewahrte Daten: {path}", ["path": path])
        }
        alert(tr("Paketentfernung noch offen"), summary)
    }
    @objc func uninstallPackageRemainder() {
        guard !busy else { return }
        let a = NSAlert()
        a.messageText = tr("Verbliebenes ClamAV-Paket entfernen?")
        a.informativeText = tr("Die Automatik ist bereits entfernt. Die App prüft, ob andere Programme ClamAV noch benötigen. Geschützte ClamAV-Programmordner werden bei Bedarf mit deinem Administrator-Passwort für die normale Homebrew-Deinstallation freigegeben. Archive, Quarantäne, Logs und Homebrew bleiben erhalten.")
        a.addButton(withTitle: tr("Abbrechen")); a.addButton(withTitle: tr("Reparieren und entfernen"))
        a.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self = self else { return }
            self.monitoring = false
            self.run("--repair-uninstall-package", installing: true, heading: tr("Paketentfernung wird vorbereitet …")) { code, text in
                guard !self.wasCancelled else { return }
                if code == 0 && (text.contains("@@CLAMAV:RESULT:UNINSTALLED") || text.contains("@@CLAMAV:RESULT:NOT_INSTALLED")) {
                    self.statusLabel.stringValue = tr("ClamAV-Paket entfernt · Archive bleiben erhalten")
                    self.finishUninstall(tr("Die Paketentfernung ist abgeschlossen. Vorhandene Archive, Quarantäne und Logs bleiben erhalten."))
                } else if text.contains("@@CLAMAV:RESULT:PARTIAL_UNINSTALL") {
                    self.showPartialUninstall(text)
                } else {
                    self.alert(tr("Paketentfernung noch offen"), tr("Bitte das Protokoll prüfen. Bereits archivierte Daten bleiben erhalten."))
                }
            }
        }
    }
    @objc func uninstallLegacy() {
        guard !busy else { return }
        let a = NSAlert()
        a.messageText = tr("Bisherige ClamAV-Einrichtung entfernen?")
        a.informativeText = tr("Die bisherigen täglichen Scans, Signaturupdates und der Homebrew-Hintergrunddienst werden beendet und ihre Jobdateien zusammen mit dem alten Scan-Skript archiviert. Quarantäne und Logs bleiben an ihrem bisherigen Ort. Homebrew, das ClamAV-Paket und dessen gemeinsame Konfiguration bleiben erhalten.")
        a.addButton(withTitle: tr("Abbrechen"))
        a.addButton(withTitle: tr("Deinstallieren"))
        a.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self = self else { return }
            self.monitoring = false
            self.run("--uninstall-legacy", installing: true, heading: tr("Bisherige Einrichtung wird entfernt …")) { code, text in
                guard !self.wasCancelled else { return }
                if code == 0 && text.contains("@@CLAMAV:RESULT:UNINSTALLED") {
                    self.statusLabel.stringValue = tr("Bisherige Einrichtung entfernt · Daten bleiben erhalten")
                    let prefix = "@@CLAMAV:ARCHIVE:"
                    let path = text.components(separatedBy: .newlines).last(where: { $0.hasPrefix(prefix) })
                        .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                    self.finishUninstall(tr("Die bisherige Einrichtung wurde entfernt. Sicherung: {path}\n\nQuarantäne: {quarantine}\nLogs: {logs}\n\nDu kannst jetzt mit Schritt 01 die neue Automatik einrichten.", ["path": path, "quarantine": home.appendingPathComponent("ClamAV-Quarantine").path, "logs": home.appendingPathComponent("Library/Logs/ClamAV").path]))
                } else if code == 0 && text.contains("@@CLAMAV:RESULT:NOT_INSTALLED") {
                    self.statusLabel.stringValue = tr("Es wurde keine bisherige Einrichtung gefunden.")
                    self.finishUninstall(tr("Es wurde keine bisherige Einrichtung gefunden."))
                } else if self.preview && code == 0 {
                    self.statusLabel.stringValue = tr("Vorschautest abgeschlossen")
                } else {
                    self.alert(tr("Einrichtung konnte nicht entfernt werden"), tr("Bitte das Protokoll prüfen. Läuft gerade ein Scan oder Signaturupdate, warte dessen Abschluss ab und versuche es erneut. Bei veränderten oder unbekannten Jobdateien bricht die App zum Schutz der bestehenden Einrichtung ab."))
                }
            }
        }
    }
    func finishUninstall(_ summary: String) {
        let title = tr("Verbleibende Berechtigungen prüfen")
        let notice = tr("macOS kann erteilte Datenschutzfreigaben nach der Deinstallation behalten.\n\nPrüfe unter Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff die Einträge clamd, clamscan, clamdscan und bash. Deaktiviere oder entferne nur Freigaben, die du nicht mehr benötigst. Bash kann auch von anderen Programmen verwendet werden.\n\nDie Freigaben musst du in den Systemeinstellungen selbst ändern.")
        footerLabel.stringValue = title
        footerLabel.textColor = .systemOrange
        addMessage("\n" + title + "\n" + notice)

        let a = NSAlert()
        a.messageText = tr("Deinstallation abgeschlossen")
        a.informativeText = summary
        // Keep the reminder readable alongside long archive paths in every language.
        let note = label(title + "\n\n" + notice, color: .labelColor)
        note.preferredMaxLayoutWidth = 520
        note.widthAnchor.constraint(equalToConstant: 520).isActive = true
        note.setFrameSize(note.fittingSize)
        a.accessoryView = note
        a.addButton(withTitle: tr("Verstanden"))
        a.addButton(withTitle: tr("Einstellungen öffnen"))
        if !openPrivacySettings() {
            let fallback = tr("Die Einstellungen konnten nicht automatisch geöffnet werden. Öffne Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff manuell.")
            a.informativeText += "\n\n" + fallback
            addMessage(fallback)
        }
        a.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.openPrivacy() }
        }
    }
    @objc func testScan() {
        guard !busy else { return }
        run("--restart", heading: tr("Scanner wird neu gestartet …")) { [weak self] code, _ in
            guard let self = self, code == 0, !self.wasCancelled else { return }
            self.lastScanAtRequest = self.readLastScan()
            self.run("--scan-now", heading: tr("Hintergrundscan wird angefordert …")) { code, _ in
                if code == 0 && !self.wasCancelled {
                    self.monitoring = true; self.monitorStarted = Date()
                    self.statusLabel.stringValue = tr("Scan angefordert · Ergebnis wird beobachtet")
                    self.refreshLocalState()
                }
            }
        }
    }
    func readLastScan() -> String {
        ((try? String(contentsOf: logs.appendingPathComponent("last-scan.txt"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func refreshLocalState() {
        if !busy {
            installButton.title = tr("Installieren / aktualisieren")
            testButton.isEnabled = installed || preview
            uninstallButton.title = !managed && packagePresent ? tr("ClamAV-Paket entfernen…") : tr("Deinstallieren…")
            uninstallButton.isEnabled = managed || packagePresent || preview
            uninstallButton.isHidden = !managed && legacyPresent && !preview
            legacyUninstallButton.isEnabled = legacyPresent || preview
            legacyUninstallButton.isHidden = !(legacyPresent || preview)
            legacyNotice.isHidden = !(legacyPresent || preview)
        }
        let value = readLastScan().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            resultLabel.stringValue = tr("Noch kein Scan mit dieser Einrichtung abgeschlossen.")
            if monitoring, let since = monitorStarted, Date().timeIntervalSince(since) > 60, !busy {
                statusLabel.stringValue = tr("Noch kein neues Scanergebnis · Status oder Logs prüfen")
            }
            return
        }
        let time = String(value.split(separator: "|", maxSplits: 1).first ?? "")
        let summary = value.contains("LAEUFT:") ? tr("Scan läuft") :
            value.contains("UNVOLLSTAENDIG:") ? tr("Scan unvollständig") :
            value.contains("FEHLER:") ? tr("Scan fehlgeschlagen") :
            value.contains("FUNDE:") ? tr("Funde in Quarantäne") :
            value.contains("OK:") ? tr("Keine Bedrohung erkannt") : tr("Details in den Logs")
        resultLabel.stringValue = tr("Letzter Scan: {result}\n{time}", ["result": tr(summary), "time": time])
        resultLabel.textColor = value.contains("UNVOLLSTAENDIG:") || value.contains("FEHLER:") ? .systemOrange : .secondaryLabelColor
        if !busy && (value.contains("LAEUFT:") || monitoring || scanPanelVisible) {
            showBackgroundScan(value)
        }
    }
    func checkScanJob() {
        guard !scanJobCheckPending, Date().timeIntervalSince(scanJobCheckAt) >= 5 else { return }
        scanJobCheckPending = true; scanJobCheckAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process(), output = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["print", "gui/\(getuid())/local.clamav.automatik.scan"]
            p.standardOutput = output; p.standardError = FileHandle.nullDevice
            var active: Bool?
            do {
                try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                active = ScanSnapshot.jobRunning(String(decoding: data, as: UTF8.self), exitCode: p.terminationStatus)
            } catch { active = nil }
            DispatchQueue.main.async {
                self?.scanJobRunning = active; self?.scanJobCheckPending = false
            }
        }
    }
    func showBackgroundScan(_ value: String) {
        let scan = ScanSnapshot(status: value, logs: logs)
        if monitoring && value == lastScanAtRequest && !scan.running {
            progressStack.isHidden = false; progressBar.isHidden = false
            progressBar.isIndeterminate = true; progressBar.startAnimation(nil)
            statusLabel.stringValue = tr("Scan angefordert · Ergebnis wird beobachtet")
            if let since = monitorStarted, Date().timeIntervalSince(since) > 60 {
                statusLabel.stringValue = tr("Noch kein neues Scanergebnis · Status oder Logs prüfen")
                progressBar.stopAnimation(nil)
            }
            return
        }
        scanPanelVisible = true; progressStack.isHidden = false
        inputStack.isHidden = true; cancelButton.isHidden = true
        progressBar.isIndeterminate = scan.running
        if scan.running {
            checkScanJob()
            if scanJobRunning == true { progressBar.startAnimation(nil) } else { progressBar.stopAnimation(nil) }
            statusLabel.stringValue = scanJobRunning == true ? tr("Hintergrundscan läuft …") :
                (scanJobRunning == false ? tr("Scanstatus prüfen · Hintergrundjob nicht aktiv") : tr("Scan gemeldet · Jobstatus noch nicht verfügbar"))
            statusLabel.textColor = scanJobRunning == true ? accent : .systemOrange
            progressLabel.stringValue = tr("Scan-Auftrag: Downloads · Schreibtisch · Dokumente")
            progressHint.stringValue = tr("ClamAV meldet keine verlässliche Prozentzahl oder Restzeit. Ein aktiver Job allein bestätigt noch keinen vollständigen Scan.")
        } else {
            monitoring = false; progressBar.stopAnimation(nil); progressBar.isHidden = true
            let ok = value.contains("OK:")
            statusLabel.stringValue = ok ? tr("Scan abgeschlossen · keine Bedrohung erkannt") :
                (value.contains("FUNDE:") ? tr("Scan abgeschlossen · Funde in Quarantäne") : tr("Scan unvollständig · Protokoll prüfen"))
            statusLabel.textColor = ok ? accent : .systemOrange
            progressLabel.stringValue = tr("Hintergrundscan beendet")
            progressHint.stringValue = tr("Das Endergebnis steht unten und im Scanprotokoll.")
        }
        if scan.running { progressBar.isHidden = false }
        progressHint.textColor = .secondaryLabelColor
        let duration = scan.elapsed(at: Date()) ?? "—"
        let start = scan.started.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "—"
        activityLabel.stringValue = tr("Scan-Laufzeit {elapsed} · Beginn {time}", ["elapsed": duration, "time": start])
        if scan.logText.isEmpty {
            latestMessageLabel.stringValue = tr("Noch keine Scanprotokoll-Ausgabe verfügbar.")
        } else if scan.truncated {
            latestMessageLabel.stringValue = tr("Viele Protokollmeldungen · Details im Scanprotokoll")
        } else if scan.findings > 0 || scan.errors > 0 || scan.warnings > 0 {
            latestMessageLabel.stringValue = tr("Protokoll bisher · Fundmeldungen: {findings} · Fehlermeldungen: {errors} · Warnungen: {warnings}", ["findings": String(scan.findings), "errors": String(scan.errors), "warnings": String(scan.warnings)])
        } else {
            latestMessageLabel.stringValue = scan.running ? tr("Bisher keine Fund- oder Fehlermeldungen · Ergebnis noch vorläufig") : tr("Details im Scanprotokoll")
        }
        latestMessageLabel.textColor = scan.findings > 0 || scan.errors > 0 || scan.warnings > 0 ? .systemOrange : .labelColor
        let text = scan.logText.isEmpty ? tr("Noch keine Scanprotokoll-Ausgabe verfügbar.") : scan.logText
        if console.string != text { console.string = text; console.scrollToEndOfDocument(nil) }
        footerLabel.stringValue = tr("Scananzeige wird automatisch aktualisiert · Protokoll anzeigen für Details")
        if monitoring, let since = monitorStarted, value == lastScanAtRequest, Date().timeIntervalSince(since) < 60, !scan.running {
            statusLabel.stringValue = tr("Scan angefordert · Ergebnis wird beobachtet")
        }
    }

    @objc func toggleDetails() {
        logScroll.isHidden.toggle()
        detailButton.title = logScroll.isHidden ? tr("Protokoll anzeigen") : tr("Protokoll ausblenden")
    }
    @objc func sendPassword() {
        guard busy, secureInputAllowed, !waitingForReturn, !waitingForYesNo, !wasCancelled, !streamReadFailed, let input = stdinHandle else { NSSound.beep(); return }
        let value = passwordField.stringValue
        guard !value.isEmpty else { return }
        guard value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            addMessage(tr("Das Passwort darf keine Zeilenumbrüche oder Steuerzeichen enthalten.")); return
        }
        secrets.append(value)
        passwordField.stringValue = ""
        do { try input.write(contentsOf: Data(("P" + value + "\n").utf8)) } catch { addMessage(tr("Eingabe konnte nicht gesendet werden.")) }
    }
    @objc func sendReturn() {
        guard busy, waitingForReturn, !wasCancelled, !streamReadFailed, let input = stdinHandle else { return }
        guard promptState.consume(.returnKey) else { return }
        refreshActivity()
        do {
            try input.write(contentsOf: Data("R\n".utf8))
        } catch { addMessage(tr("Bestätigung konnte nicht gesendet werden.")) }
    }
    @objc func sendYes() { sendYesNo(true) }
    @objc func sendNo() { sendYesNo(false) }
    func sendYesNo(_ yes: Bool) {
        guard busy, waitingForYesNo, !wasCancelled, !streamReadFailed,
              let input = stdinHandle, promptState.consume(.yesNo) else { return }
        // Consume before writing: a double click cannot answer the next prompt.
        setSecureInput(false)
        refreshActivity()
        do { try input.write(contentsOf: Data((yes ? "Y\n" : "N\n").utf8)) }
        catch { addMessage(tr("Bestätigung konnte nicht gesendet werden.")) }
    }
    @objc func cancelOperation() {
        guard busy else { return }
        let a = NSAlert(); a.messageText = tr("Vorgang abbrechen?")
        a.informativeText = tr("Bereits installierte Pakete und vorhandene Daten bleiben erhalten. Eine unvollständige Einrichtung kannst du später erneut starten.")
        a.addButton(withTitle: tr("Weiter ausführen")); a.addButton(withTitle: tr("Abbrechen"))
        a.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn {
                self?.wasCancelled = true; self?.promptState.reset(); self?.setSecureInput(false); self?.refreshActivity(); self?.process?.terminate()
            }
        }
    }
    func openPrivacySettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return false }
        return NSWorkspace.shared.open(url)
    }
    @objc func openPrivacy() {
        if !openPrivacySettings() {
            alert(tr("Verbleibende Berechtigungen prüfen"), tr("Die Einstellungen konnten nicht automatisch geöffnet werden. Öffne Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff manuell."))
        }
    }
    @objc func showFDA() {
        let scanner = URL(fileURLWithPath: "/opt/homebrew/opt/clamav/bin/clamdscan").resolvingSymlinksInPath().path
        let a = NSAlert(); a.messageText = tr("Festplattenvollzugriff erlauben")
        a.informativeText = tr("In Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff auf + klicken. Mit ⌘⇧G die folgenden Programme auswählen und aktivieren:\n\n/bin/bash\n{scanner}\n\nDie Freigabe für Bash gilt auch für andere darüber gestartete Skripte. Nur diese Installer-App oder Terminal freizugeben genügt für den Hintergrundjob nicht.\n\nDanach hier „Neustarten & Scan testen“ wählen. Erst der echte Hintergrundscan zeigt, ob die Zugriffe funktionieren.", ["scanner": scanner])
        a.addButton(withTitle: tr("Verstanden")); a.addButton(withTitle: tr("Pfade kopieren")); a.addButton(withTitle: tr("Einstellungen öffnen"))
        a.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("/bin/bash\n" + scanner, forType: .string)
            } else if response == .alertThirdButtonReturn { self?.openPrivacy() }
        }
    }
    func openFolder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { alert(tr("Ordner noch nicht vorhanden"), tr("Der Ordner wird während der Einrichtung angelegt.")) }
    }
    @objc func openLogs() { openFolder(logs) }
    @objc func openQuarantine() { openFolder(base.appendingPathComponent("quarantine")) }
    @objc func openManual() {
        alert(tr("Anleitung"), tr("1. Sprache wählen und „Installieren / aktualisieren“ anklicken. Fehlendes Homebrew wird automatisch eingerichtet. Ein Administrator-Passwort oder Apples Entwicklerwerkzeuge können nötig sein.\n\n2. Den Festplattenvollzugriff mit der Freigabe-Anleitung manuell erteilen.\n\n3. „Neustarten & Scan testen“ anklicken und das Ergebnis abwarten. Geplante Scans laufen im angemeldeten Benutzerkonto auch bei geschlossener App.\n\n4. Zum Entfernen „Deinstallieren…“ wählen. Daten werden archiviert. Das gemeinsam genutzte ClamAV-Paket kann optional entfernt werden; Homebrew bleibt erhalten.\n\nDie Oberfläche ist übersetzt. Technische Originalprotokolle von Installer, Homebrew und ClamAV bleiben in ihrer Originalsprache.\n\nQuarantänedateien nicht öffnen. Cloud-Dateien, verschlüsselte Inhalte und Grössenlimits können die Prüfung begrenzen. Festplattenvollzugriff kann nach Updates erneut nötig sein.\n\nNach erfolgreicher Deinstallation erscheint ein Hinweis auf verbleibende Datenschutzfreigaben. Die App öffnet automatisch den Festplattenvollzugriff in den Systemeinstellungen. Nicht mehr benötigte Freigaben dort manuell deaktivieren oder entfernen.\n\nWährend der Einrichtung zeigt die App den aktuellen Schritt, dessen Fortschritt, die Laufzeit und die letzte Meldung. Die Prozentanzeige zählt Einrichtungsschritte und ist keine Zeitprognose. Passwort- und Bestätigungsabfragen erscheinen oben im Fenster.\n\nBei jedem Start verwendet die App die macOS-Systemsprache. Wird sie nicht unterstützt, startet die App auf Englisch. Eine manuelle Sprachwahl gilt nur für das aktuelle Fenster.\n\nBleibt nach der Deinstallation das Homebrew-Paket zurück, zeigt die App dies getrennt an. Mit „ClamAV-Paket entfernen…“ kannst du die Entfernung wiederholen. Geschützte ClamAV-Programmordner werden bei Bedarf nach einer Administrator-Passwortabfrage repariert. Archive und Logs bleiben erhalten."))
    }
    @objc func about() {
        alert(tr("ClamAV Installer 1.0"), tr("Native Oberfläche für die ClamAV-Automatik auf Apple Silicon.\n\nAd-hoc signiert, ohne Zertifikat; nicht von Apple notarisiert.\n\nHomebrew wird bei Bedarf automatisch installiert. Jede Installation aktualisiert die Paketdaten und installiert die neueste dort verfügbare stabile ClamAV-Version.\n\nClamAV ist ein geplanter Scanner, kein Echtzeitschutz für macOS."))
    }
    func alert(_ title: String, _ message: String) {
        let a = NSAlert(); a.messageText = tr(title); a.informativeText = tr(message)
        a.addButton(withTitle: "OK"); a.beginSheetModal(for: window)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy { alert(tr("Ein Vorgang läuft noch"), tr("Bitte den Vorgang abschliessen oder mit „Vorgang abbrechen“ beenden, bevor du die App schliesst.")); return false }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { alert(tr("Ein Vorgang läuft noch"), tr("Bitte zuerst abschliessen oder über „Vorgang abbrechen“ beenden.")); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--check-localizations") {
    print("Interface language: \(AppLanguage.shared.code)")
    let errors = AppLanguage.shared.validationErrors()
    guard errors.isEmpty else { fputs(errors.joined(separator: "\n") + "\n", stderr); exit(2) }
    print("PASS: All six language catalogs have matching keys and placeholders.")
    if CommandLine.arguments.contains("--check-localizations") { exit(0) }
    guard let resources = Bundle.main.resourceURL else { fputs("Resources fehlen\n", stderr); exit(2) }
    let script = resources.appendingPathComponent("install.sh")
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pty-bridge")
    for url in [script, helper, Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/package-repair"), resources.appendingPathComponent("Anleitung.txt")] {
        guard FileManager.default.fileExists(atPath: url.path) else { fputs("Datei fehlt: \(url.path)\n", stderr); exit(2) }
    }
    let p = Process(); p.executableURL = helper; p.arguments = ["/bin/bash", script.path, "--help"]
    let input = Pipe(), output = Pipe(), control = Pipe()
    p.standardInput = input; p.standardOutput = output; p.standardError = control
    do {
        try p.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0, text.contains("ClamAV Automatik") else { fputs(text, stderr); exit(2) }
        print("PASS: Bundle, PTY-Start und eingebettete Installer-Hilfe.")
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(2) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
