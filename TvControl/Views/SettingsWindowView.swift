//
//  SettingsWindowView.swift
//  TvControl
//
//  Fenêtre de paramètres épurée :
//  1. Téléviseurs Wi-Fi (détection et sélection de la TV)
//  2. Général
//  3. Mise à jour GitHub
//

import SwiftUI
import AppKit

public enum SettingsTab: String, CaseIterable, Identifiable {
    case tvs = "tvs"
    case general = "general"
    case updates = "updates"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tvs: return "TV Wi-Fi"
        case .general: return "Général"
        case .updates: return "Mise à jour"
        }
    }

    public var symbol: String {
        switch self {
        case .tvs: return "tv"
        case .general: return "gearshape"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

struct SettingsWindowView: View {
    @ObservedObject var discoveryManager: TVDiscoveryManager
    @ObservedObject var timerManager: SleepTimerManager
    @ObservedObject var tvController: TVController
    @ObservedObject var updateManager: UpdateManager

    @State var selectedTab: SettingsTab = .tvs

    @State private var showAddManualSheet: Bool = false
    @State private var manualName: String = "Ma TV"
    @State private var manualIP: String = ""
    @State private var manualBrand: TVBrand = .samsung

    public var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case .tvs:
                        wifiTVsSection
                    case .general:
                        generalSection
                    case .updates:
                        updatesSection
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 450, height: 380)
        .onAppear {
            if discoveryManager.discoveredTVs.isEmpty && !discoveryManager.isScanning {
                discoveryManager.startScan()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTvControlSettingsTab)) { note in
            if let tab = note.object as? SettingsTab {
                selectedTab = tab
            }
        }
        .sheet(isPresented: $showAddManualSheet) {
            manualTVSheet
        }
    }

    // MARK: - Barre d'onglets

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = (selectedTab == tab)
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    }
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Onglet 1 : TV Wi-Fi

    private var wifiTVsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Téléviseurs détectés sur le Wi-Fi")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Sélectionnez la TV qui s'éteindra à la fin du minuteur.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    manualIP = discoveryManager.localWiFiIP?.components(separatedBy: ".").dropLast().joined(separator: ".").appending(".") ?? "192.168.1."
                    showAddManualSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Ajouter une TV par IP")

                Button {
                    if discoveryManager.isScanning {
                        discoveryManager.stopScan()
                    } else {
                        discoveryManager.startScan()
                    }
                } label: {
                    if discoveryManager.isScanning {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small).scaleEffect(0.65)
                            Text("Scan...")
                        }
                    } else {
                        Label("Rechercher", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            SettingsBox {
                if discoveryManager.discoveredTVs.isEmpty {
                    VStack(spacing: 8) {
                        if discoveryManager.isScanning {
                            ProgressView()
                            Text("Recherche des TV sur votre Wi-Fi...")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        } else {
                            Image(systemName: "tv")
                                .font(.system(size: 24, weight: .light))
                                .foregroundColor(.secondary)
                            Text("Aucune TV détectée")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Allumez votre TV sur le même Wi-Fi puis cliquez sur Rechercher.")
                                .font(.system(size: 11))
                                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    VStack(spacing: 6) {
                        ForEach(discoveryManager.discoveredTVs) { tv in
                            DiscoveredTVRow(
                                tv: tv,
                                isSelected: discoveryManager.selectedTV?.id == tv.id,
                                isBusy: tvController.isSendingCommand,
                                onSelect: {
                                    discoveryManager.selectTV(tv)
                                },
                                onTestTurnOff: {
                                    Task {
                                        _ = await tvController.turnOff(tv: tv)
                                    }
                                },
                                onDelete: {
                                    discoveryManager.removeTV(tv)
                                }
                            )
                        }
                    }
                }
            }

            if let status = tvController.lastStatusMessage {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Onglet 2 : Général

    private var generalSection: some View {
        SettingsBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Lancer TvControl au démarrage de macOS", isOn: Binding(
                    get: { timerManager.isLaunchAtLoginEnabled },
                    set: { _ in timerManager.toggleLaunchAtLogin() }
                ))

                Divider()

                Toggle("Afficher le temps restant dans la barre des menus", isOn: $timerManager.showCountdownInMenuBar)

                Divider()

                Toggle("Notification 5 minutes avant l'extinction", isOn: $timerManager.notifyBeforeShutdown)

                Divider()

                Toggle("Son de confirmation lors de l'extinction", isOn: $timerManager.soundEnabled)
            }
        }
    }

    // MARK: - Onglet 3 : Mise à jour GitHub

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsBox {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("TvControl")
                            .font(.system(size: 15, weight: .bold))
                        Text("Version installée : v\(updateManager.currentAppVersion)")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Toggle("Auto", isOn: $updateManager.autoCheckEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            SettingsBox {
                switch updateManager.state {
                case .idle:
                    HStack {
                        Text("Vérifier les mises à jour sur GitHub")
                            .font(.system(size: 12))
                        Spacer()
                        Button("Rechercher") {
                            updateManager.checkForUpdates(manual: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Recherche sur GitHub...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                case .upToDate(let version):
                    HStack {
                        Label("TvControl est à jour (v\(version))", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Vérifier") {
                            updateManager.checkForUpdates(manual: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                case .updateAvailable(let version, _, _):
                    HStack {
                        Label("Nouvelle version disponible : v\(version)", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Spacer()
                        Button("Installer") {
                            updateManager.downloadAndInstall()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Téléchargement... \(Int(progress * 100))%")
                            .font(.system(size: 12))
                        ProgressView(value: progress)
                    }

                case .readyToRestart(let version):
                    HStack {
                        Text("v\(version) prête à installer")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Redémarrer") {
                            updateManager.applyUpdateAndRelaunch()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                case .installing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Installation en cours...")
                            .font(.system(size: 12))
                    }

                case .error(let message):
                    HStack {
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button("Réessayer") {
                            updateManager.checkForUpdates(manual: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Ajout manuel par IP

    private var manualTVSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajouter une TV par IP")
                .font(.system(size: 14, weight: .bold))

            Form {
                TextField("Nom :", text: $manualName)
                TextField("Adresse IP :", text: $manualIP)
                Picker("Marque :", selection: $manualBrand) {
                    ForEach(TVBrand.allCases) { brand in
                        Text(brand.rawValue).tag(brand)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Annuler") {
                    showAddManualSheet = false
                }
                Button("Ajouter") {
                    let cleanIP = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanIP.isEmpty else { return }
                    let tv = SmartTV(
                        name: manualName.isEmpty ? manualBrand.rawValue : manualName,
                        ipAddress: cleanIP,
                        port: manualBrand.defaultPort,
                        brand: manualBrand,
                        isOnline: true
                    )
                    discoveryManager.addOrUpdateTV(tv, autoSelect: true)
                    showAddManualSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

// MARK: - Ligne d'une TV détectée

private struct DiscoveredTVRow: View {
    let tv: SmartTV
    let isSelected: Bool
    let isBusy: Bool
    let onSelect: () -> Void
    let onTestTurnOff: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tv.brand.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tv.name.replacingOccurrences(of: "[TV] ", with: ""))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 3) {
                        Circle()
                            .fill(tv.isOnline ? Color.green : Color.red.opacity(0.8))
                            .frame(width: 5.5, height: 5.5)
                        Text(tv.isOnline ? "Allumée" : "Éteinte")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(tv.isOnline ? .green : .secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background((tv.isOnline ? Color.green : Color.secondary).opacity(0.12))
                    .clipShape(Capsule())
                }
                Text("\(tv.brand.rawValue) • \(tv.ipAddress)")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Tester") {
                onTestTurnOff()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)

            if isSelected {
                Text("Active ✓")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Button("Choisir") {
                    onSelect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
        )
    }
}

private struct SettingsBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 1)
            )
    }
}

extension Notification.Name {
    static let openTvControlSettingsTab = Notification.Name("TvControl.OpenSettingsTab")
}
