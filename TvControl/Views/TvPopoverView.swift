//
//  TvPopoverView.swift
//  TvControl
//
//  Interface ultra-compacte et minimaliste style barre des menus macOS / EjectBar.
//

import SwiftUI
import AppKit

struct TvPopoverView: View {
    @ObservedObject var timerManager: SleepTimerManager
    @ObservedObject var discoveryManager: TVDiscoveryManager
    @ObservedObject var tvController: TVController
    @ObservedObject var updateManager: UpdateManager

    var onOpenSettings: (_ tab: SettingsTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - En-tête (TvControl centré + Roue crantée à droite)
            headerView
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 3)

            // Indicateur subtil si une alarme quotidienne est programmée
            if timerManager.isAlarmEnabled {
                HStack(spacing: 4) {
                    Image(systemName: "alarm.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                    Text("Alarme : \(timerManager.formattedAlarmTime)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
            }

            // MARK: - Liste ultra-compacte des 5 minuteurs (1h, 2h, 3h, 4h, 5h)
            VStack(spacing: 2) {
                ForEach(TimerPreset.allCases) { preset in
                    let isRunningThis = timerManager.isActive && timerManager.activePreset == preset
                    TimerRowView(
                        preset: preset,
                        isActive: isRunningThis,
                        remainingText: isRunningThis ? timerManager.formattedRemaining : nil,
                        onToggle: {
                            if isRunningThis {
                                timerManager.stopTimer()
                            } else {
                                timerManager.startTimer(preset: preset)
                            }
                        }
                    )

                    if preset != TimerPreset.allCases.last {
                        Divider()
                            .opacity(0.12)
                            .padding(.leading, 36)
                    }
                }
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 5)

            // MARK: - Pied de page minimaliste (TV active + Éteindre)
            Divider()
                .opacity(0.18)

            footerView
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .frame(width: 215)
    }

    // MARK: - Header View

    private var headerView: some View {
        ZStack {
            Text("TvControl")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Menu {
                    if timerManager.isActive {
                        Button("Ajouter +15 minutes") {
                            timerManager.addMinutes(15)
                        }
                        Button("Annuler le minuteur") {
                            timerManager.stopTimer()
                        }
                        Divider()
                    }

                    if let tv = discoveryManager.selectedTV {
                        Button("Éteindre la TV maintenant") {
                            Task {
                                _ = await tvController.turnOff(tv: tv)
                            }
                        }
                        Divider()
                    }

                    Button("Alarme d'extinction (\(timerManager.formattedAlarmTime))...") {
                        onOpenSettings(.alarm)
                    }

                    Toggle("Alarme activée", isOn: Binding(
                        get: { timerManager.isAlarmEnabled },
                        set: { timerManager.isAlarmEnabled = $0 }
                    ))

                    Divider()

                    Button("Choisir la TV (Wi-Fi)...") {
                        onOpenSettings(.tvs)
                    }

                    Button("Paramètres...") {
                        onOpenSettings(.general)
                    }

                    Button("Vérifier les mises à jour...") {
                        updateManager.checkForUpdates(manual: true)
                        onOpenSettings(.updates)
                    }

                    Toggle("Lancer au démarrage", isOn: Binding(
                        get: { timerManager.isLaunchAtLoginEnabled },
                        set: { _ in timerManager.toggleLaunchAtLogin() }
                    ))

                    Divider()

                    Button("Quitter TvControl") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 14, height: 14)
            }
        }
    }

    // MARK: - Pied de page minimaliste

    private var footerView: some View {
        HStack(spacing: 5) {
            Button(action: {
                onOpenSettings(.tvs)
            }) {
                HStack(spacing: 4) {
                    if let tv = discoveryManager.selectedTV {
                        Circle()
                            .fill(tv.isOnline ? Color.green : Color.red.opacity(0.85))
                            .frame(width: 5, height: 5)

                        Text("\(cleanTVName(tv.name) ?? tv.name) • \(tv.isOnline ? "Allumée" : "Éteinte")")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Circle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 5, height: 5)

                        Text("Choisir une TV...")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { isHovered in
                if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Spacer()

            if let tv = discoveryManager.selectedTV {
                Button(action: {
                    Task {
                        _ = await tvController.turnOff(tv: tv)
                    }
                }) {
                    HStack(spacing: 2.5) {
                        if tvController.isSendingCommand {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.5)
                                .frame(width: 8, height: 8)
                        } else {
                            Image(systemName: "power")
                                .font(.system(size: 8, weight: .bold))
                        }
                        Text("Éteindre")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(tvController.isSendingCommand)
                .onHover { isHovered in
                    if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
    }

    /// Nettoie le préfixe "[TV] " que certaines TV Samsung ajoutent à leur nom réseau
    private func cleanTVName(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        return raw
            .replacingOccurrences(of: "[TV] ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Ligne de minuteur ultra-compacte

struct TimerRowView: View {
    let preset: TimerPreset
    let isActive: Bool
    let remainingText: String?
    let onToggle: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            // Badge 26x26 sobre et compact
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.orange.opacity(0.18) : Color.primary.opacity(0.06))
                    .frame(width: 26, height: 26)

                Text(preset.shortLabel)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(isActive ? .orange : .primary)
            }

            // Titre + Sous-titre (ou décompte en direct)
            VStack(alignment: .leading, spacing: 0.5) {
                Text(preset.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let remainingText = remainingText {
                    Text(remainingText)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                } else {
                    Text(preset.subtitle)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Bouton arrondi compact style EjectBar
            SimplePopoverButton(
                title: isActive ? "Stop" : "Lancer",
                isActive: isActive,
                action: onToggle
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Bouton arrondi compact identique à EjectBar

struct SimplePopoverButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(isActive ? .orange : .primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            isActive
                                ? Color.orange.opacity(0.14)
                                : (isHovered ? Color(NSColor.controlColor) : Color(NSColor.controlBackgroundColor))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(
                            isActive
                                ? Color.orange.opacity(0.45)
                                : Color(NSColor.separatorColor).opacity(0.75),
                            lineWidth: 0.75
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
