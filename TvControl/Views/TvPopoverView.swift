//
//  TvPopoverView.swift
//  TvControl
//
//  Interface minimaliste et épurée calquée à 100 % sur EjectBar.
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
            // MARK: - En-tête (TvControl centré + Roue crantée à droite, comme EjectBar)
            headerView
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            // MARK: - Liste des 5 minuteurs (1h, 2h, 3h, 4h, 5h)
            VStack(spacing: 4) {
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
                            .opacity(0.18)
                            .padding(.leading, 46)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            // MARK: - Pied de page minimaliste (TV active + Éteindre)
            Divider()
                .opacity(0.2)

            footerView
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 255)
    }

    // MARK: - Header View (identique à EjectBar)

    private var headerView: some View {
        ZStack {
            Text("TvControl")
                .font(.system(size: 11.5, weight: .medium))
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
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16, height: 16)
            }
        }
    }

    // MARK: - Pied de page minimaliste

    private var footerView: some View {
        HStack(spacing: 6) {
            Button(action: {
                onOpenSettings(.tvs)
            }) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(discoveryManager.selectedTV != nil ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)

                    Text(cleanTVName(discoveryManager.selectedTV?.name) ?? "Choisir une TV...")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                    HStack(spacing: 3) {
                        Image(systemName: "power")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("Éteindre")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
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

// MARK: - Ligne de minuteur (exactement comme DriveRowView d'EjectBar)

struct TimerRowView: View {
    let preset: TimerPreset
    let isActive: Bool
    let remainingText: String?
    let onToggle: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            // Badge 34x34 sobre
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Color.orange.opacity(0.18) : Color.primary.opacity(0.06))
                    .frame(width: 34, height: 34)

                Text(preset.shortLabel)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundColor(isActive ? .orange : .primary)
            }

            // Titre + Sous-titre (ou décompte en direct quand actif)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let remainingText = remainingText {
                    Text(remainingText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                } else {
                    Text(preset.subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Bouton style EjectButton d'EjectBar
            SimplePopoverButton(
                title: isActive ? "Stop" : "Lancer",
                isActive: isActive,
                action: onToggle
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Bouton arrondi compact identique à EjectButton d'EjectBar

struct SimplePopoverButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isActive ? .orange : .primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isActive
                                ? Color.orange.opacity(0.14)
                                : (isHovered ? Color(NSColor.controlColor) : Color(NSColor.controlBackgroundColor))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            isActive
                                ? Color.orange.opacity(0.45)
                                : Color(NSColor.separatorColor).opacity(0.75),
                            lineWidth: 1
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
