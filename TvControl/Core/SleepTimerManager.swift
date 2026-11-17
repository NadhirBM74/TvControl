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

    // MARK: - Alarme d'extinction programmée à heure fixe

    /// Alarme d'extinction activée ou non
    @Published public var isAlarmEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAlarmEnabled, forKey: "TvControl.AlarmEnabled")
            updateNextAlarmDescription()
        }
    }

    /// Heure de l'alarme (0-23)
    @Published public var alarmHour: Int {
        didSet {
            UserDefaults.standard.set(alarmHour, forKey: "TvControl.AlarmHour")
            updateNextAlarmDescription()
        }
    }

    /// Minute de l'alarme (0-59)
    @Published public var alarmMinute: Int {
        didSet {
            UserDefaults.standard.set(alarmMinute, forKey: "TvControl.AlarmMinute")
            updateNextAlarmDescription()
        }
    }

    /// Répéter l'alarme chaque jour
    @Published public var alarmRepeatDaily: Bool {
        didSet {
            UserDefaults.standard.set(alarmRepeatDaily, forKey: "TvControl.AlarmRepeatDaily")
            updateNextAlarmDescription()
        }
    }

    /// Texte décrivant la prochaine exécution de l'alarme
    @Published public private(set) var nextAlarmDescription: String = ""

    public var onMenuBarNeedsUpdate: (() -> Void)?

    private var timer: Timer?
    private var alarmTimer: Timer?
    private var lastAlarmFiredKey: String?
    private var didSendAlarmWarningForToday: Bool = false
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

        self.isAlarmEnabled = UserDefaults.standard.bool(forKey: "TvControl.AlarmEnabled")

        if UserDefaults.standard.object(forKey: "TvControl.AlarmHour") == nil {
            self.alarmHour = 23
        } else {
            self.alarmHour = UserDefaults.standard.integer(forKey: "TvControl.AlarmHour")
        }

        if UserDefaults.standard.object(forKey: "TvControl.AlarmMinute") == nil {
            self.alarmMinute = 0
        } else {
            self.alarmMinute = UserDefaults.standard.integer(forKey: "TvControl.AlarmMinute")
        }

        if UserDefaults.standard.object(forKey: "TvControl.AlarmRepeatDaily") == nil {
            self.alarmRepeatDaily = true
        } else {
            self.alarmRepeatDaily = UserDefaults.standard.bool(forKey: "TvControl.AlarmRepeatDaily")
        }

        checkLaunchAtLoginStatus()
        setupAlarmTimer()
        updateNextAlarmDescription()
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

    // MARK: - Gestion de l'Alarme d'Extinction Programmée

    /// Date synchronisée avec l'heure et la minute de l'alarme pour SwiftUI DatePicker
    public var alarmTimeDate: Date {
        get {
            var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            comp.hour = alarmHour
            comp.minute = alarmMinute
            comp.second = 0
            return Calendar.current.date(from: comp) ?? Date()
        }
        set {
            let comp = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            alarmHour = comp.hour ?? 23
            alarmMinute = comp.minute ?? 0
        }
    }

    /// Format HH:mm de l'alarme (ex: "23:00")
    public var formattedAlarmTime: String {
        return String(format: "%02d:%02d", alarmHour, alarmMinute)
    }

    /// Met à jour la description textuelle de la prochaine alarme
    public func updateNextAlarmDescription() {
        guard isAlarmEnabled else {
            nextAlarmDescription = "Alarme désactivée"
            return
        }

        let now = Date()
        let calendar = Calendar.current
        var comp = calendar.dateComponents([.year, .month, .day], from: now)
        comp.hour = alarmHour
        comp.minute = alarmMinute
        comp.second = 0

        guard var target = calendar.date(from: comp) else {
            nextAlarmDescription = "Heure programmée : \(formattedAlarmTime)"
            return
        }

        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
            nextAlarmDescription = "Prochaine extinction demain à \(formattedAlarmTime)"
        } else {
            nextAlarmDescription = "Prochaine extinction aujourd'hui à \(formattedAlarmTime)"
        }
    }

    private func setupAlarmTimer() {
        // Timer de vérification périodique toutes les 10 secondes
        alarmTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAlarm()
            }
        }
        if let alarmTimer = alarmTimer {
            RunLoop.main.add(alarmTimer, forMode: .common)
        }

        // Notification lors de la sortie de veille du Mac
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAlarm()
                self?.updateNextAlarmDescription()
            }
        }
    }

    private func checkAlarm() {
        guard isAlarmEnabled else { return }

        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)

        // Déclenchement à l'heure exacte
        if hour == alarmHour && minute == alarmMinute {
            let key = "\(calendar.component(.year, from: now))-\(calendar.component(.month, from: now))-\(calendar.component(.day, from: now))-\(hour)-\(minute)"
            if lastAlarmFiredKey != key {
                lastAlarmFiredKey = key
                triggerAlarmShutdown()
            }
            return
        }

        // Avertissement 5 minutes avant
        if notifyBeforeShutdown {
            var comp = calendar.dateComponents([.year, .month, .day], from: now)
            comp.hour = alarmHour
            comp.minute = alarmMinute
            comp.second = 0
            if var target = calendar.date(from: comp) {
                if target < now {
                    target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
                }
                let diff = Int(target.timeIntervalSince(now))
                if diff >= 285 && diff <= 305 && !didSendAlarmWarningForToday {
                    didSendAlarmWarningForToday = true
                    let tvName = TVDiscoveryManager.shared.selectedTV?.name ?? "Votre TV"
                    sendNotification(
                        title: "Alarme TV dans 5 minutes ⏰",
                        body: "\(tvName) va s'éteindre à \(formattedAlarmTime)."
                    )
                } else if diff > 360 {
                    didSendAlarmWarningForToday = false
                }
            }
        }
    }

    /// Déclenche l'extinction programmée par l'alarme
    public func triggerAlarmShutdown() {
        guard let tv = TVDiscoveryManager.shared.selectedTV else {
            sendNotification(
                title: "Alarme programmée ⚠️",
                body: "L'alarme d'extinction s'est déclenchée, mais aucune TV n'est sélectionnée dans TvControl."
            )
            return
        }

        sendNotification(
            title: "Alarme d'extinction 🌙",
            body: "Extinction de \(tv.name) à l'heure programmée (\(formattedAlarmTime))."
        )

        Task {
            let (success, message) = await TVController.shared.turnOff(tv: tv)
            if !success {
                self.sendNotification(
                    title: "Échec de l'alarme TV ⚠️",
                    body: message
                )
            }
        }

        if !alarmRepeatDaily {
            isAlarmEnabled = false
        }
        updateNextAlarmDescription()
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
