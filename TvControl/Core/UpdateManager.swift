//
//  UpdateManager.swift
//  TvControl
//
//  Système de mise à jour automatique via GitHub Releases.
//  Télécharge la dernière version (.zip ou .dmg), remplace /Applications/TvControl.app
//  et relance automatiquement l'application en un seul clic.
//

import Foundation
import SwiftUI
import AppKit
import UserNotifications
import Combine

/// Représente l'état du système de mise à jour GitHub.
public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(version: String)
    case updateAvailable(version: String, notes: String, downloadUrl: URL?)
    case downloading(progress: Double)
    case readyToRestart(version: String)
    case installing
    case error(message: String)

    public static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.installing, .installing):
            return true
        case (.upToDate(let v1), .upToDate(let v2)):
            return v1 == v2
        case (.updateAvailable(let v1, _, _), .updateAvailable(let v2, _, _)):
            return v1 == v2
        case (.downloading(let p1), .downloading(let p2)):
            return abs(p1 - p2) < 0.001
        case (.readyToRestart(let v1), .readyToRestart(let v2)):
            return v1 == v2
        case (.error(let m1), .error(let m2)):
            return m1 == m2
        default:
            return false
        }
    }
}

@MainActor
public final class UpdateManager: NSObject, ObservableObject {
    public static let shared = UpdateManager()

    public static let repoOwner = "NadhirBM74"
    public static let repoName = "TvControl"

    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var lastChecked: Date? {
        didSet {
            if let lastChecked {
                UserDefaults.standard.set(lastChecked, forKey: "TvControlLastUpdateCheckDate")
            }
        }
    }
    @Published public var autoCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckEnabled, forKey: "TvControlAutoCheckUpdates")
        }
    }

    private var activeDownloadTask: URLSessionDownloadTask?
    private var downloadObservation: NSKeyValueObservation?
    private var pendingApiAssetUrl: URL?
    private var pendingAssetExtension: String = "zip"
    private var stagedUpdateContext: (tempDir: URL, newAppURL: URL, targetAppPath: String)?

    override private init() {
        if UserDefaults.standard.object(forKey: "TvControlAutoCheckUpdates") == nil {
            self.autoCheckEnabled = true
        } else {
            self.autoCheckEnabled = UserDefaults.standard.bool(forKey: "TvControlAutoCheckUpdates")
        }
        self.lastChecked = UserDefaults.standard.object(forKey: "TvControlLastUpdateCheckDate") as? Date
        super.init()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Vérification des mises à jour

    public func checkForUpdates(manual: Bool = false) {
        guard state != .checking else { return }
        state = .checking

        Task {
            await performCheck(manual: manual)
        }
    }

    private func fetchLatestRelease() async throws -> [String: Any]? {
        // 1. API REST GitHub Releases en priorité (aucun délai de cache CDN)
        let apiEndpoints = [
            "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest",
            "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases?per_page=1"
        ]

        var lastHttpCode: Int = 0

        for endpoint in apiEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("TvControl-App/\(currentAppVersion) (Macintosh; macOS)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    lastHttpCode = httpResponse.statusCode
                    if httpResponse.statusCode == 200 {
                        if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                           let tag = dict["tag_name"] as? String, !tag.isEmpty {
                            return dict
                        } else if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
                                  let first = arr.first,
                                  let tag = first["tag_name"] as? String, !tag.isEmpty {
                            return first
                        }
                    }
                }
            } catch {
                // Repli sur raw.githubusercontent.com
            }
        }

        // 2. Repli CDN raw.githubusercontent.com (version.json avec cache-buster)
        let ts = Int(Date().timeIntervalSince1970)
        let rawEndpoints = [
            "https://raw.githubusercontent.com/\(Self.repoOwner)/\(Self.repoName)/refs/heads/main/version.json?t=\(ts)",
            "https://raw.githubusercontent.com/\(Self.repoOwner)/\(Self.repoName)/main/version.json?t=\(ts)"
        ]
        for rawEndpoint in rawEndpoints {
            if let rawUrl = URL(string: rawEndpoint) {
                var rawReq = URLRequest(url: rawUrl)
                rawReq.timeoutInterval = 5
                rawReq.cachePolicy = .reloadIgnoringLocalCacheData
                rawReq.setValue("TvControl-App/\(currentAppVersion) (Macintosh; macOS)", forHTTPHeaderField: "User-Agent")

                if let (data, response) = try? await URLSession.shared.data(for: rawReq),
                   let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode),
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let tag = json["tag_name"] as? String, !tag.isEmpty {
                    return json
                }
            }
        }

        if lastHttpCode == 404 {
            return nil
        } else if lastHttpCode > 0 {
            throw NSError(domain: "UpdateManager", code: lastHttpCode, userInfo: [
                NSLocalizedDescriptionKey: "Serveur GitHub temporairement indisponible (code \(lastHttpCode))."
            ])
        } else {
            throw NSError(domain: "UpdateManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Connexion impossible au serveur de mise à jour GitHub."
            ])
        }
    }

    private func performCheck(manual: Bool) async {
        do {
            guard let json = try await fetchLatestRelease() else {
                let current = currentAppVersion
                state = .upToDate(version: current)
                lastChecked = Date()
                return
            }

            guard let tagName = json["tag_name"] as? String else {
                state = .error(message: "Données de version introuvables.")
                return
            }

            let releaseNotes = (json["body"] as? String) ?? ""
            let htmlUrlString = (json["html_url"] as? String) ?? ""
            let htmlUrl = URL(string: htmlUrlString)

            var directAssetUrl: URL? = nil
            var directApiUrl: URL? = nil
            var detectedExt = "zip"

            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".zip"),
                       let downloadStr = asset["browser_download_url"] as? String,
                       let u = URL(string: downloadStr) {
                        directAssetUrl = u
                        detectedExt = "zip"
                        if let apiStr = asset["url"] as? String {
                            directApiUrl = URL(string: apiStr)
                        }
                        break
                    }
                }
                if directAssetUrl == nil {
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           name.hasSuffix(".dmg"),
                           let downloadStr = asset["browser_download_url"] as? String,
                           let u = URL(string: downloadStr) {
                            directAssetUrl = u
                            detectedExt = "dmg"
                            if let apiStr = asset["url"] as? String {
                                directApiUrl = URL(string: apiStr)
                            }
                            break
                        }
                    }
                }
            }

            self.pendingApiAssetUrl = directApiUrl
            self.pendingAssetExtension = detectedExt

            let currentVersion = currentAppVersion
            let cleanRemoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let isNewer = cleanRemoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending

            lastChecked = Date()

            if isNewer {
                let targetUrl = directAssetUrl ?? htmlUrl
                state = .updateAvailable(version: cleanRemoteVersion, notes: releaseNotes, downloadUrl: targetUrl)
                if !manual {
                    sendUpdateNotification(
                        title: "Mise à jour TvControl disponible ✨",
                        body: "La version v\(cleanRemoteVersion) est disponible."
                    )
                }
            } else {
                state = .upToDate(version: currentVersion)
            }
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    public var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    public var currentBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func sendUpdateNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: "tvcontrol.update.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Téléchargement et Installation Automatique

    public func downloadAndInstall() {
        guard case .updateAvailable(let version, _, let downloadUrl) = state,
              let url = downloadUrl else {
            return
        }

        let ext = url.pathExtension.isEmpty ? self.pendingAssetExtension : url.pathExtension.lowercased()
        if ext != "zip" && ext != "dmg" {
            NSWorkspace.shared.open(url)
            return
        }

        state = .downloading(progress: 0.0)
        startDownloadTask(targetUrl: url, isApiFallback: false, ext: ext, version: version)
    }

    private func startDownloadTask(targetUrl: URL, isApiFallback: Bool, ext: String, version: String) {
        var request = URLRequest(url: targetUrl)
        request.setValue("TvControl-Updater/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")
        if isApiFallback {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        } else {
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        request.timeoutInterval = 60

        let fallbackApiUrl = self.pendingApiAssetUrl
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: request) { [weak self] tempUrl, response, error in
            guard let self = self else { return }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            let isSuccessfulHttp = (200...299).contains(httpStatus)

            var validFile = false
            if let tempUrl = tempUrl, isSuccessfulHttp, error == nil {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempUrl.path)[.size] as? Int64) ?? 0
                if fileSize >= 50_000 {
                    validFile = true
                }
            }

            if !validFile, !isApiFallback, let fallbackApiUrl = fallbackApiUrl, fallbackApiUrl != targetUrl {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.startDownloadTask(targetUrl: fallbackApiUrl, isApiFallback: true, ext: ext, version: version)
                }
                return
            }

            if let error = error {
                Task { @MainActor [weak self] in
                    self?.state = .error(message: "Échec du téléchargement : \(error.localizedDescription)")
                }
                return
            }

            guard let tempUrl = tempUrl, validFile else {
                Task { @MainActor [weak self] in
                    self?.state = .error(message: "Archive téléchargée invalide (HTTP \(httpStatus)).")
                }
                return
            }

            let fileManager = FileManager.default
            let workDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let localArchive = workDir.appendingPathComponent("update.\(ext)")

            do {
                try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
                try fileManager.moveItem(at: tempUrl, to: localArchive)
            } catch {
                Task { @MainActor [weak self] in
                    self?.state = .error(message: "Erreur de préparation : \(error.localizedDescription)")
                }
                return
            }

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                await self.performInPlaceUpdate(archiveDest: localArchive, tempDir: workDir, fileExtension: ext, version: version)
            }
        }

        self.downloadObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.state = .downloading(progress: progress.fractionCompleted)
            }
        }

        self.activeDownloadTask = task
        task.resume()
    }

    private nonisolated func performInPlaceUpdate(archiveDest: URL, tempDir: URL, fileExtension: String, version: String) async {
        let fileManager = FileManager.default
        let extractedAppDir = tempDir.appendingPathComponent("Extracted")

        do {
            try fileManager.createDirectory(at: extractedAppDir, withIntermediateDirectories: true)

            if fileExtension == "zip" {
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-x", "-k", archiveDest.path, extractedAppDir.path]
                try ditto.run()
                ditto.waitUntilExit()
            } else if fileExtension == "dmg" {
                let mountPoint = tempDir.appendingPathComponent("MountPoint")
                try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

                let hdiutil = Process()
                hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                hdiutil.arguments = ["attach", archiveDest.path, "-mountpoint", mountPoint.path, "-nobrowse", "-readonly", "-quiet"]
                try hdiutil.run()
                hdiutil.waitUntilExit()

                let mountedApp = mountPoint.appendingPathComponent("TvControl.app")
                if fileManager.fileExists(atPath: mountedApp.path) {
                    let destApp = extractedAppDir.appendingPathComponent("TvControl.app")
                    let ditto = Process()
                    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    ditto.arguments = [mountedApp.path, destApp.path]
                    try ditto.run()
                    ditto.waitUntilExit()
                }

                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", mountPoint.path, "-quiet"]
                try? detach.run()
                detach.waitUntilExit()
            }

            var finalNewAppURL: URL? = nil
            if let subpaths = try? fileManager.subpathsOfDirectory(atPath: extractedAppDir.path) {
                for subpath in subpaths where subpath.hasSuffix(".app") {
                    finalNewAppURL = extractedAppDir.appendingPathComponent(subpath)
                    break
                }
            }

            guard let newAppURL = finalNewAppURL else {
                await MainActor.run {
                    self.state = .error(message: "L'application extraite est introuvable dans l'archive.")
                }
                return
            }

            let rawTargetPath = Bundle.main.bundleURL.path
            let resolvedTargetAppPath: String
            if rawTargetPath.hasPrefix("/Volumes/") || rawTargetPath.contains("DerivedData") || rawTargetPath.contains("/var/folders/") || !fileManager.fileExists(atPath: rawTargetPath) {
                resolvedTargetAppPath = "/Applications/TvControl.app"
            } else {
                resolvedTargetAppPath = rawTargetPath
            }

            // Lance immédiatement l'installation et le redémarrage dès la fin de l'extraction
            await MainActor.run {
                self.stagedUpdateContext = (tempDir, newAppURL, resolvedTargetAppPath)
                self.applyUpdateAndRelaunch()
            }
        } catch {
            await MainActor.run {
                self.state = .error(message: "Erreur d'installation : \(error.localizedDescription)")
            }
        }
    }

    public func applyUpdateAndRelaunch() {
        guard let context = stagedUpdateContext else {
            state = .error(message: "Aucune mise à jour prête à installer.")
            return
        }

        state = .installing

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let scriptURL = context.tempDir.appendingPathComponent("relaunch.sh")
        let scriptContent = """
        #!/bin/bash
        exec > /tmp/tvcontrol_updater.log 2>&1
        set -x

        PID=\(currentPID)
        NEW_APP="\(context.newAppURL.path)"
        TARGET_APP="\(context.targetAppPath)"
        TEMP_DIR="\(context.tempDir.path)"

        COUNT=0
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.2
            COUNT=$((COUNT + 1))
            if [ $COUNT -ge 15 ]; then
                kill -9 "$PID" 2>/dev/null || true
                break
            fi
        done

        /usr/bin/xattr -r -d com.apple.quarantine "$NEW_APP" 2>/dev/null || true
        rm -rf "$TARGET_APP"
        /usr/bin/ditto "$NEW_APP" "$TARGET_APP"
        /usr/bin/xattr -cr "$TARGET_APP" 2>/dev/null || true
        /usr/bin/codesign --force --deep --sign - --identifier "com.tvcontrol.app" "$TARGET_APP" 2>/dev/null || true

        sleep 0.4
        /usr/bin/open "$TARGET_APP" || /usr/bin/open -n "$TARGET_APP"
        rm -rf "$TEMP_DIR"
        """

        do {
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)

            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", scriptURL.path]
            try chmod.run()
            chmod.waitUntilExit()

            let relaunchProcess = Process()
            relaunchProcess.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
            relaunchProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            relaunchProcess.arguments = ["-c", "/usr/bin/nohup /bin/bash \"\(scriptURL.path)\" >/tmp/tvcontrol_updater.log 2>&1 &"]
            relaunchProcess.standardOutput = FileHandle.nullDevice
            relaunchProcess.standardError = FileHandle.nullDevice
            relaunchProcess.standardInput = FileHandle.nullDevice
            try relaunchProcess.run()

            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                exit(0)
            }
        } catch {
            state = .error(message: "Erreur lors du redémarrage : \(error.localizedDescription)")
        }
    }

    public func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadObservation = nil
        state = .idle
    }
}
