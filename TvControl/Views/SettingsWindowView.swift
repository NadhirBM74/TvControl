//
//  SettingsWindowView.swift
//  TvControl
//
//  Fenêtre de paramètres de TvControl :
//  - Détection et sélection de la TV à éteindre sur le réseau Wi-Fi
//  - Options du minuteur et lancement au démarrage
//  - Système de mise à jour automatique sur GitHub (style LaunchPad)
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
        case .tvs: return "Téléviseurs Wi-Fi"
        case .general: return "Général & Minuteur"
        case .updates: return "Mise à jour"
        }
    }

    public var symbol: String {
        switch self {
        case .tvs: return "tv.and.mediabox"
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

    // Formulaire d'ajout manuel d'une TV
    @State private var showAddManualSheet: Bool = false
    @State private var manualName: String = "Ma TV Salon"
    @State private var manualIP: String = ""
    @State private var manualBrand: TVBrand = .samsung
    @State private var manualTokenOrPSK: String = ""

    public var body: some View {
        VStack(spacing: 0) {
            // Barre d'onglets supérieure
            tabBar
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch selectedTab {
                    case .tvs:
                        wifiTVsSection
                    case .general:
                        generalSection
                    case .updates:
                        updatesSection
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 560, height: 500)
        .onAppear {
            if discoveryManager.discoveredTVs.isEmpty && !discoveryManager.isScanning {
                discoveryManager.startScan()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTvControlSettingsTab)) { note in
            if let tab = note.object as? SettingsTab {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTab = tab
                }
            }
        }
        .sheet(isPresented: $showAddManualSheet) {
            manualTVSheet
        }
    }

    // MARK: - Barre d'onglets

    private var tabBar: some View {
        HStack(spacing: 10) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = (selectedTab == tab)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 13, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    }
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Onglet 1 : Détection et Sélection de la TV Wi-Fi

    private var wifiTVsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // En-tête du scanner Wi-Fi
            SettingsBox {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: "wifi")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Détection des TV sur le réseau Wi-Fi")
                            .font(.system(size: 13.5, weight: .semibold))
                        if let ip = discoveryManager.localWiFiIP {
                            Text("Réseau local actif (\(ip)) • SSDP, Bonjour/mDNS & Scan Smart TV")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else {
                            Text("Recherche automatique des téléviseurs connectés à votre Wi-Fi")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        if discoveryManager.isScanning {
                            discoveryManager.stopScan()
                        } else {
                            discoveryManager.startScan()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if discoveryManager.isScanning {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                Text("Scan en cours...")
                            } else {
                                Image(systemName: "arrow.clockwise")
                                Text("Scanner le Wi-Fi")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            // Liste des TV détectées
            SettingsBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Choisissez la TV à éteindre à la fin du minuteur")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Button {
                            manualIP = discoveryManager.localWiFiIP?.components(separatedBy: ".").dropLast().joined(separator: ".").appending(".") ?? "192.168.1."
                            showAddManualSheet = true
                        } label: {
                            Label("Ajouter par IP...", systemImage: "plus")
                                .font(.system(size: 11.5))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    if discoveryManager.discoveredTVs.isEmpty {
                        VStack(spacing: 8) {
                            if discoveryManager.isScanning {
                                ProgressView()
                                    .padding(.top, 6)
                                Text("Recherche des téléviseurs sur votre réseau Wi-Fi...")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "tv.and.mediabox")
                                    .font(.system(size: 26, weight: .light))
                                    .foregroundColor(.secondary.opacity(0.6))
                                Text("Aucune télévision détectée pour l'instant")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            Text("Assurez-vous que votre TV est allumée et connectée au même Wi-Fi que votre Mac, ou ajoutez-la par son adresse IP.")
                                .font(.system(size: 11))
                                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(discoveryManager.discoveredTVs) { tv in
                                DiscoveredTVRow(
                                    tv: tv,
                                    isSelected: discoveryManager.selectedTV?.id == tv.id,
                                    isBusy: tvController.isSendingCommand,
                                    onSelect: {
                                        discoveryManager.selectTV(tv)
                                    },
                                    onPair: {
                                        Task {
                                            _ = await tvController.pair(tv: tv)
                                        }
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
            }

            // Bannière de retour d'état lors d'un test d'extinction ou d'appairage
            if let status = tvController.lastStatusMessage {
                SettingsBox {
                    HStack(spacing: 8) {
                        Image(systemName: (tvController.lastCommandSucceeded == false) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor((tvController.lastCommandSucceeded == false) ? .orange : .green)
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Onglet 2 : Général & Minuteur

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Comportement de la barre des menus")
                        .font(.system(size: 13, weight: .semibold))

                    Toggle("Lancer TvControl automatiquement au démarrage de macOS", isOn: Binding(
                        get: { timerManager.isLaunchAtLoginEnabled },
                        set: { _ in timerManager.toggleLaunchAtLogin() }
                    ))

                    Toggle("Afficher le temps restant (ex: 1h 45m) à côté de l'icône dans la barre de menu", isOn: $timerManager.showCountdownInMenuBar)

                    Toggle("Envoyer une notification macOS 5 minutes avant l'extinction de la TV", isOn: $timerManager.notifyBeforeShutdown)

                    Toggle("Jouer un son de confirmation lors de l'extinction (comme EjectBar)", isOn: $timerManager.soundEnabled)
                }
            }

            SettingsBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Raccourcis de minuteur rapide")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Vous pouvez lancer les minuteurs 1h, 2h, 3h, 4h et 5h directement depuis l'icône de la barre des menus.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        ForEach(TimerPreset.allCases) { preset in
                            Button {
                                timerManager.startTimer(preset: preset)
                            } label: {
                                Text(preset.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Onglet 3 : Système de mise à jour GitHub (identique à LaunchPad)

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // En-tête de l'application
            SettingsBox {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("TvControl")
                                .font(.system(size: 17, weight: .bold))
                            Text("PRO")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }

                        HStack(spacing: 6) {
                            Text("Version installée :")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text("v\(updateManager.currentAppVersion)")
                                .font(.system(size: 11.5, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(Capsule())
                        }

                        Text("Dépôt GitHub : \(UpdateManager.repoOwner)/\(UpdateManager.repoName)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }

            // Carte de mise à jour GitHub
            SettingsBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.15))
                                .frame(width: 32, height: 32)
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mise à jour du logiciel (GitHub Releases)")
                                .font(.system(size: 13.5, weight: .semibold))
                            if let lastChecked = updateManager.lastChecked {
                                Text("Dernière vérification : \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Vérification automatique sur GitHub activée")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Toggle("Vérif. auto", isOn: $updateManager.autoCheckEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Divider()

                    switch updateManager.state {
                    case .idle:
                        HStack {
                            Text("Rechercher si une nouvelle version est disponible sur GitHub.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Rechercher") {
                                updateManager.checkForUpdates(manual: true)
                            }
                            .buttonStyle(.bordered)
                        }

                    case .checking:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Recherche de mises à jour sur GitHub...")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                    case .upToDate(let version):
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("TvControl est à jour (v\(version))")
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            Spacer()
                            Button("Vérifier à nouveau") {
                                updateManager.checkForUpdates(manual: true)
                            }
                            .buttonStyle(.bordered)
                        }

                    case .updateAvailable(let version, let notes, _):
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                        .foregroundColor(.accentColor)
                                    Text("Nouvelle version disponible : v\(version)")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.accentColor)
                                }
                                Spacer()
                                Button {
                                    updateManager.downloadAndInstall()
                                } label: {
                                    Label("Télécharger et installer", systemImage: "arrow.down.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(notes)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }

                    case .downloading(let progress):
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Téléchargement de la mise à jour... \(Int(progress * 100))%")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Button("Annuler") {
                                    updateManager.cancelDownload()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            ProgressView(value: progress)
                        }

                    case .readyToRestart(let version):
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Mise à jour v\(version) prête à être installée !")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            Spacer()
                            Button("Installer et redémarrer") {
                                updateManager.applyUpdateAndRelaunch()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                    case .installing:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Installation et redémarrage en cours...")
                                .font(.system(size: 12))
                        }

                    case .error(let message):
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(message)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Réessayer") {
                                updateManager.checkForUpdates(manual: true)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Feuille d'ajout manuel d'une TV par IP

    private var manualTVSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajouter une Smart TV manuellement")
                .font(.system(size: 15, weight: .bold))

            Form {
                TextField("Nom de la TV :", text: $manualName)
                TextField("Adresse IP Wi-Fi (ex: 192.168.1.45) :", text: $manualIP)
                Picker("Marque / Protocole :", selection: $manualBrand) {
                    ForEach(TVBrand.allCases) { brand in
                        Text(brand.rawValue).tag(brand)
                    }
                }
                TextField("Clé PSK / Token (optionnel) :", text: $manualTokenOrPSK)
            }

            Text(manualBrand.protocolSummary)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Annuler") {
                    showAddManualSheet = false
                }
                Button("Ajouter et sélectionner") {
                    let cleanIP = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanIP.isEmpty else { return }
                    let tv = SmartTV(
                        name: manualName.isEmpty ? manualBrand.rawValue : manualName,
                        ipAddress: cleanIP,
                        port: manualBrand.defaultPort,
                        brand: manualBrand,
                        isOnline: true,
                        pairingToken: manualTokenOrPSK.isEmpty ? nil : manualTokenOrPSK
                    )
                    discoveryManager.addOrUpdateTV(tv, autoSelect: true)
                    showAddManualSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Ligne d'une TV détectée dans les Paramètres

private struct DiscoveredTVRow: View {
    let tv: SmartTV
    let isSelected: Bool
    let isBusy: Bool
    let onSelect: () -> Void
    let onPair: () -> Void
    let onTestTurnOff: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                    .frame(width: 36, height: 36)
                Image(systemName: tv.brand.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tv.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    if isSelected {
                        Text("Sélectionnée")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                Text("\(tv.brand.rawValue) • IP : \(tv.ipAddress)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if tv.brand.supportsPairing {
                Button("Associer") {
                    onPair()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
                .help("Associer TvControl avec l'écran de la TV")
            }

            Button("Tester l'extinction") {
                onTestTurnOff()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)

            if !isSelected {
                Button("Choisir") {
                    onSelect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Supprimer cette TV de la liste")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Conteneur de Carte des Paramètres

private struct SettingsBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
    }
}

extension Notification.Name {
    static let openTvControlSettingsTab = Notification.Name("TvControl.OpenSettingsTab")
}
