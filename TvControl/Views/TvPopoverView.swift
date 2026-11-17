//
//  TvPopoverView.swift
//  TvControl
//
//  Interface compacte de barre des menus calquée sur le design épuré d'EjectBar.
//  Permet de lancer un minuteur (1h, 2h, 3h, 4h, 5h), voir le décompte actif,
//  éteindre immédiatement la TV ou ouvrir les paramètres Wi-Fi & GitHub.
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
            // MARK: - En-tête (TvControl centré + Roue crantée à droite, identique à EjectBar)
            headerView
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 5)

            // MARK: - Téléviseur actif sélectionné
            selectedTVBar
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            Divider()
                .opacity(0.2)
                .padding(.horizontal, 10)

            // MARK: - Carte du minuteur actif (si un minuteur tourne)
            if timerManager.isActive {
                activeTimerBanner
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                Divider()
                    .opacity(0.18)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            // MARK: - Liste des choix de minuteur (1h, 2h, 3h, 4h, 5h) style EjectBar
            VStack(spacing: 3) {
                ForEach(TimerPreset.allCases) { preset in
                    TimerPresetRowView(
                        preset: preset,
                        isRunningThisPreset: timerManager.isActive && timerManager.activePreset == preset,
                        action: {
                            timerManager.startTimer(preset: preset)
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
            .padding(.vertical, 6)

            // MARK: - Message de statut éventuel
            if let status = tvController.lastStatusMessage ?? timerManager.statusBannerMessage {
                Divider()
                    .opacity(0.16)
                HStack(spacing: 6) {
                    if tvController.isSendingCommand {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: (tvController.lastCommandSucceeded == false) ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor((tvController.lastCommandSucceeded == false) ? .orange : .secondary)
                    }
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }

            // MARK: - Pied de page style EjectBar
            Divider()
                .opacity(0.2)

            footerView
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 270)
    }

    // MARK: - Header View (Style EjectBar)

    private var headerView: some View {
        ZStack {
            Text("TvControl")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)

            HStack {
                if case .updateAvailable(let v, _, _) = updateManager.state {
                    Button(action: { onOpenSettings(.updates) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 10))
                            Text("v\(v)")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Mise à jour disponible : v\(v)")
                }

                Spacer()

                Menu {
                    Section("Téléviseur cible") {
                        if discoveryManager.discoveredTVs.isEmpty {
                            Button("Rechercher ma TV sur le Wi-Fi...") {
                                onOpenSettings(.tvs)
                            }
                        } else {
                            ForEach(discoveryManager.discoveredTVs) { tv in
                                Button {
                                    discoveryManager.selectTV(tv)
                                } label: {
                                    HStack {
                                        Text(tv.name)
                                        if discoveryManager.selectedTV?.id == tv.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Détecter les TV sur le Wi-Fi...") {
                                onOpenSettings(.tvs)
                            }
                        }
                    }

                    Divider()

                    if let tv = discoveryManager.selectedTV {
                        Button("Éteindre « \(tv.name) » maintenant") {
                            Task {
                                _ = await tvController.turnOff(tv: tv)
                            }
                        }
                    }

                    if timerManager.isActive {
                        Button("Annuler le minuteur en cours") {
                            timerManager.stopTimer()
                        }
                    }

                    Divider()

                    Button("Paramètres...") {
                        onOpenSettings(.tvs)
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

    // MARK: - Bandeau TV Sélectionnée

    private var selectedTVBar: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)

                Image(systemName: discoveryManager.selectedTV?.brand.symbolName ?? "tv.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(discoveryManager.selectedTV != nil ? .accentColor : .secondary)
            }

            if let tv = discoveryManager.selectedTV {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(tv.isOnline ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(tv.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(tv.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                CompactActionButton(
                    title: "Éteindre",
                    icon: "power",
                    isLoading: tvController.isSendingCommand,
                    action: {
                        Task {
                            _ = await tvController.turnOff(tv: tv)
                        }
                    }
                )
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aucune TV sélectionnée")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("Cliquez sur Choisir pour scanner le Wi-Fi")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                CompactActionButton(
                    title: "Choisir",
                    icon: "wifi",
                    isLoading: false,
                    action: {
                        onOpenSettings(.tvs)
                    }
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    // MARK: - Bandeau du Minuteur Actif

    private var activeTimerBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("Extinction prévue à \(timerManager.formattedTargetTime)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(timerManager.formattedRemaining)
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            }

            ProgressView(value: timerManager.progress)
                .controlSize(.small)
                .tint(.orange)

            HStack(spacing: 6) {
                CompactActionButton(
                    title: "+15 min",
                    icon: "plus",
                    isLoading: false,
                    action: {
                        timerManager.addMinutes(15)
                    }
                )

                Spacer()

                CompactActionButton(
                    title: "Annuler le minuteur",
                    icon: "xmark",
                    isLoading: false,
                    action: {
                        timerManager.stopTimer()
                    }
                )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Pied de page

    private var footerView: some View {
        HStack {
            Button(action: {
                onOpenSettings(.tvs)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 9))
                    Text("Choisir la TV (Wi-Fi)")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .onHover { isHovered in
                if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Spacer()

            Button(action: {
                onOpenSettings(.general)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9))
                    Text("Paramètres")
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

// MARK: - Ligne d'un choix de minuteur (1h, 2h, 3h, 4h, 5h) - Design EjectBar

struct TimerPresetRowView: View {
    let preset: TimerPreset
    let isRunningThisPreset: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            // Icône badge heure style EjectBar (34x34)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isRunningThisPreset
                            ? Color.orange.opacity(0.20)
                            : Color(NSColor.controlBackgroundColor)
                    )
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                isRunningThisPreset
                                    ? Color.orange.opacity(0.55)
                                    : Color(NSColor.separatorColor).opacity(0.6),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)

                Text(preset.shortLabel)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundColor(isRunningThisPreset ? .orange : .primary)
            }

            // Titre (ex: 1 heure) + heure d'extinction
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(preset.subtitle)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Bouton d'action arrondi compact identique au bouton "Eject" d'EjectBar
            CompactActionButton(
                title: isRunningThisPreset ? "Actif" : "Lancer",
                icon: isRunningThisPreset ? "checkmark" : "timer",
                isLoading: false,
                isHighlighted: isRunningThisPreset,
                action: action
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

// MARK: - Bouton Compact style EjectButton d'EjectBar

struct CompactActionButton: View {
    let title: String
    var icon: String? = nil
    let isLoading: Bool
    var isHighlighted: Bool = false
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHighlighted ? .orange : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isHighlighted
                            ? Color.orange.opacity(0.14)
                            : (isHovered ? Color(NSColor.controlColor) : Color(NSColor.controlBackgroundColor))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        isHighlighted
                            ? Color.orange.opacity(0.45)
                            : Color(NSColor.separatorColor).opacity(0.75),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
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
