//
//  AppDelegate.swift
//  TvControl
//
//  Point d'entrée principal de l'application barre des menus (style EjectBar).
//  Gère le NSStatusItem, le Popover SwiftUI des minuteurs (1h, 2h, 3h, 4h, 5h),
//  la fenêtre de paramètres Wi-Fi et la vérification des mises à jour GitHub.
//

import Cocoa
import SwiftUI

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var settingsWindow: NSWindow?

    private let timerManager = SleepTimerManager.shared
    private let discoveryManager = TVDiscoveryManager.shared
    private let tvController = TVController.shared
    private let updateManager = UpdateManager.shared

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupEventMonitor()

        timerManager.onMenuBarNeedsUpdate = { [weak self] in
            self?.updateStatusItemAppearance()
        }

        // Si aucune TV n'est encore enregistrée, lancer un scan Wi-Fi silencieux au démarrage
        if discoveryManager.discoveredTVs.isEmpty {
            discoveryManager.startScan()
        }

        // Vérification automatique des mises à jour sur GitHub au lancement
        if updateManager.autoCheckEnabled {
            updateManager.checkForUpdates(manual: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Configuration du Status Item (Barre des menus)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let symbolName = timerManager.isActive ? "tv.fill" : "tv"
        if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "TvControl") {
            symbolImage.isTemplate = true
            button.image = symbolImage
        }

        if let countdown = timerManager.menuBarCountdownText {
            button.title = countdown
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - Configuration du Popover (Style EjectBar)

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let popoverContent = TvPopoverView(
            timerManager: timerManager,
            discoveryManager: discoveryManager,
            tvController: tvController,
            updateManager: updateManager,
            onOpenSettings: { [weak self] tab in
                self?.closePopover(nil)
                self?.openSettingsWindow(tab: tab)
            }
        )
        let hostingController = NSHostingController(rootView: popoverContent)
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
    }

    // MARK: - Événements de clic sur l'icône de barre de menu

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let currentEvent = NSApp.currentEvent

        if currentEvent?.type == .rightMouseUp {
            showContextMenu(sender)
            return
        }

        togglePopover(sender)
    }

    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(button)
        }
    }

    private func showPopover(_ button: NSStatusBarButton) {
        Task {
            await discoveryManager.pingAllTVsNow()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover(_ sender: AnyObject?) {
        popover.performClose(sender)
    }

    // MARK: - Fermeture au clic extérieur

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.closePopover(nil)
        }
    }

    // MARK: - Menu contextuel rapide (Clic droit, comme EjectBar)

    private func showContextMenu(_ button: NSStatusBarButton) {
        let menu = NSMenu()

        let tvTitle = discoveryManager.selectedTV?.name ?? "Aucune TV sélectionnée"
        let headerItem = NSMenuItem(title: "TV : \(tvTitle)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        for preset in TimerPreset.allCases {
            let item = NSMenuItem(
                title: "Minuteur \(preset.title)",
                action: #selector(startPresetFromMenu(_:)),
                keyEquivalent: "\(preset.hours)"
            )
            item.tag = preset.rawValue
            item.target = self
            if timerManager.isActive && timerManager.activePreset == preset {
                item.state = .on
            }
            menu.addItem(item)
        }

        if timerManager.isActive {
            menu.addItem(NSMenuItem.separator())
            let cancelItem = NSMenuItem(title: "Annuler le minuteur (\(timerManager.formattedRemaining))", action: #selector(cancelTimerAction), keyEquivalent: "")
            cancelItem.target = self
            menu.addItem(cancelItem)
        }

        menu.addItem(NSMenuItem.separator())

        if discoveryManager.selectedTV != nil {
            let powerOffItem = NSMenuItem(title: "Éteindre la TV maintenant", action: #selector(turnOffNowAction), keyEquivalent: "p")
            powerOffItem.target = self
            menu.addItem(powerOffItem)
        }

        let settingsItem = NSMenuItem(title: "Paramètres & Détection Wi-Fi...", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: "Vérifier les mises à jour...", action: #selector(checkUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quitter TvControl", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func startPresetFromMenu(_ sender: NSMenuItem) {
        if let preset = TimerPreset(rawValue: sender.tag) {
            timerManager.startTimer(preset: preset)
        }
    }

    @objc private func cancelTimerAction() {
        timerManager.stopTimer()
    }

    @objc private func turnOffNowAction() {
        guard let tv = discoveryManager.selectedTV else { return }
        Task {
            _ = await tvController.turnOff(tv: tv)
        }
    }

    @objc private func openSettingsAction() {
        openSettingsWindow(tab: .tvs)
    }

    @objc private func checkUpdatesAction() {
        updateManager.checkForUpdates(manual: true)
        openSettingsWindow(tab: .updates)
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(self)
    }

    // MARK: - Fenêtre des Paramètres

    func openSettingsWindow(tab: SettingsTab = .tvs) {
        if settingsWindow == nil {
            let rootView = SettingsWindowView(
                discoveryManager: discoveryManager,
                timerManager: timerManager,
                tvController: tvController,
                updateManager: updateManager,
                selectedTab: tab
            )
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Paramètres TvControl"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.center()
            window.isReleasedWhenClosed = false
            self.settingsWindow = window
        }

        NotificationCenter.default.post(name: .openTvControlSettingsTab, object: tab)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
