//
//  SleepTimerManager.swift
//  TvControl
//
//  Gestionnaire du minuteur d'extinction de la TV (choix 1h, 2h, 3h, 4h, 5h)
//  avec affichage temps réel dans la barre des menus macOS et prévention de mise en veille.
//

import Foundation
import Combine
import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

@MainActor
public final class SleepTimerManager: ObservableObject {
    public static let shared = SleepTimerManager()

    /// Indique si un minuteur est actuellement en cours
    @Published public private(set) var isActive: Bool = false

    /// Préréglage sélectionné (1h, 2h, 3h, 4h, 5h)
    @Published public private(set) var activePreset: TimerPreset?

    /// Nombre total de secondes du minuteur lancé
    @Published public private(set) var totalSeconds: Int = 0

    /// Nombre de secondes restantes avant l'extinction de la TV
    @Published public private(set) var remainingSeconds: Int = 0

    /// Date exacte prévue pour l'extinction
    @Published public private(set) var targetDate: Date?

    /// Message de statut de la dernière action
    @Published public var statusBannerMessage: String?

    /// Lancement au démarrage de macOS
    @Published public var isLaunchAtLoginEnabled: Bool = false

    /// Afficher le décompte à côté de l'icône dans la barre des menus
    @Published public var showCountdownInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showCountdownInMenuBar, forKey: "TvControl.ShowCountdownInMenuBar")
            onMenuBarNeedsUpdate?()
        }
    }

    /// Notification 5 minutes avant l'extinction
    @Published public var notifyBeforeShutdown: Bool {
        didSet {
            UserDefaults.standard.set(notifyBeforeShutdown, forKey: "TvControl.NotifyBeforeShutdown")
        }
    }

    /// Son de confirmation activé
    @Published public var soundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEnabled, forKey: "TvControl.SoundEnabled")
        }
    }

    public var onMenuBarNeedsUpdate: (() -> Void)?

    private var timer: Timer?
    private var sleepPreventionActivity: NSObjectProtocol?
    private var didSendFiveMinuteWarning: Bool = false

    private init() {
        if UserDefaults.standard.object(forKey: "TvControl.ShowCountdownInMenuBar") == nil {
            self.showCountdownInMenuBar = true
        } else {
            self.showCountdownInMenuBar = UserDefaults.standard.bool(forKey: "TvControl.ShowCountdownInMenuBar")
        }

        if UserDefaults.standard.object(forKey: "TvControl.NotifyBeforeShutdown") == nil {
            self.notifyBeforeShutdown = true
        } else {
            self.notifyBeforeShutdown = UserDefaults.standard.bool(forKey: "TvControl.NotifyBeforeShutdown")
        }

        if UserDefaults.standard.object(forKey: "TvControl.SoundEnabled") == nil {
            self.soundEnabled = true
        } else {
            self.soundEnabled = UserDefaults.standard.bool(forKey: "TvControl.SoundEnabled")
        }

        checkLaunchAtLoginStatus()
    }

    // MARK: - Contrôle du Minuteur

    /// Lance un minuteur à partir d'un choix (1h, 2h, 3h, 4h, 5h)
    public func startTimer(preset: TimerPreset) {
        startTimer(seconds: preset.seconds, preset: preset)
    }

    /// Lance un minuteur pour une durée personnalisée en secondes
    public func startTimer(seconds: Int, preset: TimerPreset? = nil) {
        stopTimer(silent: true)

        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(seconds))

        withAnimation(.easeInOut(duration: 0.2)) {
            self.activePreset = preset
            self.totalSeconds = seconds
            self.remainingSeconds = seconds
            self.targetDate = end
            self.isActive = true
            self.didSendFiveMinuteWarning = false
            if let tv = TVDiscoveryManager.shared.selectedTV {
                self.statusBannerMessage = "Minuteur lancé : \(tv.name) s'éteindra à \(Self.formatClockTime(end))"
            } else {
                self.statusBannerMessage = "Minuteur lancé (sélectionnez une TV dans les paramètres)"
            }
        }

        // Empêche le Mac de se mettre en veille profonde pendant que le minuteur tourne
        sleepPreventionActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Minuteur d'extinction TV TvControl actif"
        )

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        onMenuBarNeedsUpdate?()
    }

    /// Ajoute ou retire des minutes au minuteur actif
    public func addMinutes(_ minutes: Int) {
        guard isActive, let currentTarget = targetDate else { return }
        let delta = minutes * 60
        let newTarget = currentTarget.addingTimeInterval(TimeInterval(delta))
        let newRemaining = max(10, Int(ceil(newTarget.timeIntervalSinceNow)))

        withAnimation(.easeInOut(duration: 0.15)) {
            self.targetDate = newTarget
            self.totalSeconds = max(self.totalSeconds, newRemaining)
            self.remainingSeconds = newRemaining
            self.activePreset = nil
        }
        onMenuBarNeedsUpdate?()
    }

    /// Annule le minuteur en cours
    public func stopTimer(silent: Bool = false) {
        timer?.invalidate()
        timer = nil

        if let activity = sleepPreventionActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepPreventionActivity = nil
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            isActive = false
            activePreset = nil
            remainingSeconds = 0
            totalSeconds = 0
            targetDate = nil
            if !silent {
                statusBannerMessage = "Minuteur annulé."
            }
        }

        onMenuBarNeedsUpdate?()
    }

    private func tick() {
        guard isActive, let target = targetDate else { return }
        let diff = Int(ceil(target.timeIntervalSinceNow))

        if diff <= 0 {
            remainingSeconds = 0
            onMenuBarNeedsUpdate?()
            triggerTVShutdown()
            return
        }

        remainingSeconds = diff

        // Avertissement à 5 minutes (300 secondes)
        if notifyBeforeShutdown && !didSendFiveMinuteWarning && diff == 300 {
            didSendFiveMinuteWarning = true
            let tvName = TVDiscoveryManager.shared.selectedTV?.name ?? "Votre TV"
            sendNotification(
                title: "Extinction TV dans 5 minutes 🌙",
                body: "\(tvName) va s'éteindre automatiquement dans 5 minutes."
            )
        }

        onMenuBarNeedsUpdate?()
    }

    private func triggerTVShutdown() {
        stopTimer(silent: true)

        guard let tv = TVDiscoveryManager.shared.selectedTV else {
            statusBannerMessage = "Minuteur terminé, mais aucune TV n'est sélectionnée."
            sendNotification(
                title: "Minuteur terminé ⚠️",
                body: "Aucune TV n'était sélectionnée dans les paramètres de TvControl."
            )
            return
        }

        statusBannerMessage = "Extinction de \(tv.name) en cours..."
        Task {
            let (success, message) = await TVController.shared.turnOff(tv: tv)
            self.statusBannerMessage = message
            self.sendNotification(
                title: success ? "\(tv.name) éteinte 🌙" : "Échec de l'extinction TV ⚠️",
                body: message
            )
        }
    }

    // MARK: - Formatage pour l'UI et la Barre des Menus

    /// Progression entre 0.0 et 1.0
    public var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSeconds - remainingSeconds) / Double(totalSeconds)
    }

    /// Format complet HH:MM:SS (ex: 01:42:09)
    public var formattedRemaining: String {
        let h = remainingSeconds / 3600
        let m = (remainingSeconds % 3600) / 60
        let s = remainingSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Format compact pour la barre de menu macOS (ex: "1h 42m" ou "04:59")
    public var menuBarCountdownText: String? {
        guard isActive, showCountdownInMenuBar else { return nil }
        let h = remainingSeconds / 3600
        let m = (remainingSeconds % 3600) / 60
        let s = remainingSeconds % 60
        if h > 0 {
            return String(format: " %dh %02dm", h, m)
        } else {
            return String(format: " %02d:%02d", m, s)
        }
    }

    public var formattedTargetTime: String {
        guard let targetDate = targetDate else { return "--:--" }
        return Self.formatClockTime(targetDate)
    }

    private static func formatClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Notifications macOS

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "tvcontrol.timer.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Lancement au démarrage (Launch at Login)

    public func checkLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            isLaunchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    public func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if isLaunchAtLoginEnabled {
                    try SMAppService.mainApp.unregister()
                    isLaunchAtLoginEnabled = false
                } else {
                    try SMAppService.mainApp.register()
                    isLaunchAtLoginEnabled = true
                }
            } catch {
                print("Erreur Launch at Login: \(error)")
            }
        }
    }
}
