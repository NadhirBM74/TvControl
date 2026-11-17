//
//  TVController.swift
//  TvControl
//
//  Moteur d'extinction Wi-Fi multi-marques avec Mode Rafale (envoie plusieurs
//  requêtes simultanées et en salves successives vérifiées par ping pour garantir
//  que la TV s'éteint à 100 %).
//

import Foundation
import AppKit

@MainActor
public final class TVController: ObservableObject {
    public static let shared = TVController()

    @Published public private(set) var isSendingCommand: Bool = false
    @Published public var lastStatusMessage: String?
    @Published public var lastCommandSucceeded: Bool?

    private init() {}

    /// Éteint la télévision en lançant une rafale de requêtes simultanées + salves de sécurité
    /// vérifiées par ping jusqu'à confirmation de l'extinction.
    public func turnOff(tv: SmartTV) async -> (success: Bool, message: String) {
        isSendingCommand = true
        lastStatusMessage = "Envoi de la rafale d'extinction à \(tv.name)..."
        lastCommandSucceeded = nil

        defer {
            isSendingCommand = false
        }

        var anyWaveSucceeded = false
        var lastMessage = ""

        // Jusqu'à 3 salves parallèles (s'arrête dès que le ping confirme que la TV est éteinte)
        for wave in 1...3 {
            let currentTV = TVDiscoveryManager.shared.discoveredTVs.first(where: { $0.id == tv.id }) ?? tv

            let waveResult = await executeParallelBurstWave(tv: currentTV, waveIndex: wave)
            if waveResult.0 {
                anyWaveSucceeded = true
                lastMessage = waveResult.1
            } else if lastMessage.isEmpty {
                lastMessage = waveResult.1
            }

            // Pause courte puis ping de vérification de l'état de la TV
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            let stillOn = await TVDiscoveryManager.shared.pingTV(currentTV)
            if !stillOn {
                // La TV ne répond plus au ping / indique Standby -> elle est bien éteinte !
                anyWaveSucceeded = true
                lastMessage = "\(tv.name.replacingOccurrences(of: "[TV] ", with: "")) est éteinte."
                break
            }
        }

        // Dernier ping après 1 seconde pour rafraîchir l'indicateur Allumée/Éteinte
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await TVDiscoveryManager.shared.pingTV(tv)
        }

        lastCommandSucceeded = anyWaveSucceeded
        lastStatusMessage = lastMessage

        if anyWaveSucceeded {
            if UserDefaults.standard.object(forKey: "TvControl.SoundEnabled") == nil ||
               UserDefaults.standard.bool(forKey: "TvControl.SoundEnabled") {
                NSSound(named: "Blow")?.play()
            }
        } else {
            NSSound.beep()
        }

        return (anyWaveSucceeded, lastMessage)
    }

    /// Exécute une salve de requêtes simultanées sur tous les canaux disponibles de la TV.
    private func executeParallelBurstWave(tv: SmartTV, waveIndex: Int) async -> (Bool, String) {
        switch tv.brand {
        case .samsung:
            return await burstTurnOffSamsung(tv: tv, waveIndex: waveIndex)
        case .lgWebOS:
            return await burstTurnOffLGWebOS(tv: tv)
        case .roku:
            return await burstTurnOffRoku(tv: tv)
        case .sonyBravia:
            return await burstTurnOffSonyBravia(tv: tv)
        case .philips:
            return await burstTurnOffPhilips(tv: tv)
        case .androidTV:
            return await burstTurnOffAndroidTV(tv: tv)
        case .appleTV, .dlnaUPnP:
            // Lance simultanément tous les protocoles constructeurs sur l'IP
            return await withTaskGroup(of: (Bool, String).self) { group in
                group.addTask { await self.burstTurnOffSamsung(tv: tv, waveIndex: waveIndex) }
                group.addTask { await self.burstTurnOffLGWebOS(tv: tv) }
                group.addTask { await self.burstTurnOffRoku(tv: tv) }
                group.addTask { await self.burstTurnOffSonyBravia(tv: tv) }
                group.addTask { await self.burstTurnOffPhilips(tv: tv) }

                for await res in group where res.0 {
                    group.cancelAll()
                    return res
                }
                return (false, "Aucune réponse de \(tv.name) (\(tv.ipAddress)).")
            }
        case .customWebhook:
            return await triggerCustomWebhook(tv: tv)
        }
    }

    /// Associe (pair) la télévision sans l'éteindre.
    public func pair(tv: SmartTV) async -> (success: Bool, message: String) {
        isSendingCommand = true
        lastStatusMessage = "Demande d'association envoyée à \(tv.name)..."
        defer { isSendingCommand = false }

        let result: (Bool, String)
        switch tv.brand {
        case .samsung:
            result = await sendSamsungWebSocketBurst(tv: tv, port: 8002, secure: true, pairOnly: true)
        case .lgWebOS:
            result = await burstTurnOffLGWebOS(tv: tv, pairOnly: true)
        default:
            result = (true, "Aucun appairage requis pour \(tv.brand.rawValue).")
        }

        lastCommandSucceeded = result.0
        lastStatusMessage = result.1
        return result
    }

    // MARK: - 1. Rafale Samsung Smart TV (Tizen WSS 8002 + WS 8001 simultanés)

    private func burstTurnOffSamsung(tv: SmartTV, waveIndex: Int) async -> (Bool, String) {
        // Lance en parallèle sur le port sécurisé 8002 (WSS) et le port 8001 (WS)
        await withTaskGroup(of: (Bool, String).self) { group in
            group.addTask {
                await self.sendSamsungWebSocketBurst(tv: tv, port: 8002, secure: true, pairOnly: false, includeTogglePower: waveIndex == 1)
            }
            group.addTask {
                await self.sendSamsungWebSocketBurst(tv: tv, port: 8001, secure: false, pairOnly: false, includeTogglePower: waveIndex == 1)
            }

            var anySuccess = false
            var bestMsg = "Impossible de joindre \(tv.name) (\(tv.ipAddress))."
            for await (ok, msg) in group {
                if ok {
                    anySuccess = true
                    bestMsg = msg
                } else if !anySuccess {
                    bestMsg = msg
                }
            }
            return (anySuccess, bestMsg)
        }
    }

    private func sendSamsungWebSocketBurst(
        tv: SmartTV,
        port: Int,
        secure: Bool,
        pairOnly: Bool,
        includeTogglePower: Bool = true
    ) async -> (Bool, String) {
        let scheme = secure ? "wss" : "ws"
        let appNameBase64 = Data("TvControl".utf8).base64EncodedString()
        var tokenQuery = ""
        if let token = tv.pairingToken, !token.isEmpty {
            tokenQuery = "&token=\(token)"
        }

        guard let wsURL = URL(string: "\(scheme)://\(tv.ipAddress):\(port)/api/v2/channels/samsung.remote.control?name=\(appNameBase64)\(tokenQuery)") else {
            return (false, "URL Samsung invalide.")
        }

        let delegate = InsecureTLSURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let wsTask = session.webSocketTask(with: wsURL)
        wsTask.resume()

        do {
            let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask {
                    try await wsTask.receive()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                    throw URLError(.timedOut)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            if case .string(let text) = message,
               let data = text.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let event = json["event"] as? String ?? ""
                if let payloadData = json["data"] as? [String: Any],
                   let newToken = payloadData["token"] as? String, !newToken.isEmpty {
                    TVDiscoveryManager.shared.updatePairingToken(for: tv.id, token: newToken)
                }

                if event == "ms.channel.unauthorized" {
                    wsTask.cancel(with: .goingAway, reason: nil)
                    return (false, "Autorisez « TvControl » sur l'écran de votre TV Samsung.")
                }
            }

            if pairOnly {
                wsTask.cancel(with: .normalClosure, reason: nil)
                return (true, "TV Samsung associée avec succès !")
            }

            // Envoi d'une rafale de commandes d'extinction sur la connexion WebSocket ouverte
            var burstPayloads: [(cmd: String, key: String)] = [
                ("Click", "KEY_POWEROFF"),
                ("Click", "KEY_POWEROFF"),
                ("Press", "KEY_POWEROFF"),
                ("Release", "KEY_POWEROFF")
            ]
            if includeTogglePower {
                burstPayloads.append(("Click", "KEY_POWER"))
            }

            for item in burstPayloads {
                let commandPayload: [String: Any] = [
                    "method": "ms.remote.control",
                    "params": [
                        "Cmd": item.cmd,
                        "DataOfCmd": item.key,
                        "Option": "false",
                        "TypeOfRemote": "SendRemoteKey"
                    ]
                ]
                if let cmdData = try? JSONSerialization.data(withJSONObject: commandPayload),
                   let cmdStr = String(data: cmdData, encoding: .utf8) {
                    try? await wsTask.send(.string(cmdStr))
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }

            wsTask.cancel(with: .normalClosure, reason: nil)
            return (true, "Rafale d'extinction envoyée à \(tv.name).")
        } catch {
            wsTask.cancel(with: .goingAway, reason: nil)
            return (false, "TV hors ligne ou injoignable sur le port \(port).")
        }
    }

    // MARK: - 2. Rafale LG webOS TV (SSAP WebSocket ports 3000 & 3001 simultanés)

    private func burstTurnOffLGWebOS(tv: SmartTV, pairOnly: Bool = false) async -> (Bool, String) {
        let urls = [
            URL(string: "ws://\(tv.ipAddress):3000"),
            URL(string: "wss://\(tv.ipAddress):3001")
        ].compactMap { $0 }

        return await withTaskGroup(of: (Bool, String).self) { group in
            for wsURL in urls {
                group.addTask {
                    await self.sendLGWebSocketBurst(tv: tv, wsURL: wsURL, pairOnly: pairOnly)
                }
            }
            for await (ok, msg) in group where ok {
                return (ok, msg)
            }
            return (false, "Impossible de se connecter à la TV LG (\(tv.ipAddress)).")
        }
    }

    private func sendLGWebSocketBurst(tv: SmartTV, wsURL: URL, pairOnly: Bool) async -> (Bool, String) {
        let delegate = InsecureTLSURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let wsTask = session.webSocketTask(with: wsURL)
        wsTask.resume()

        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": [
                "manifestVersion": 1,
                "appVersion": "1.0.0",
                "permissions": [
                    "CONTROL_POWER",
                    "CONTROL_INPUT_TEXT",
                    "CONTROL_MOUSE_AND_KEYBOARD",
                    "READ_INSTALLED_APPS",
                    "READ_POWER_STATE"
                ]
            ]
        ]
        if let key = tv.pairingToken, !key.isEmpty {
            payload["client-key"] = key
        }

        let registerPacket: [String: Any] = [
            "type": "register",
            "id": "register_0",
            "payload": payload
        ]

        do {
            let regData = try JSONSerialization.data(withJSONObject: registerPacket)
            let regString = String(data: regData, encoding: .utf8) ?? "{}"
            try await wsTask.send(.string(regString))

            var isRegistered = false
            for _ in 0..<2 {
                let msg = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                    group.addTask { try await wsTask.receive() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 8_000_000_000)
                        throw URLError(.timedOut)
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }

                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let msgType = json["type"] as? String ?? ""
                    if msgType == "registered" {
                        isRegistered = true
                        if let respPayload = json["payload"] as? [String: Any],
                           let clientKey = respPayload["client-key"] as? String {
                            TVDiscoveryManager.shared.updatePairingToken(for: tv.id, token: clientKey)
                        }
                        break
                    }
                }
            }

            guard isRegistered else {
                wsTask.cancel(with: .goingAway, reason: nil)
                return (false, "Association requise sur la TV LG.")
            }

            if pairOnly {
                wsTask.cancel(with: .normalClosure, reason: nil)
                return (true, "TV LG associée avec succès !")
            }

            // Envoi en rafale (3 paquets ssap://system/turnOff successifs)
            for idx in 1...3 {
                let turnOffPacket: [String: Any] = [
                    "id": "power_off_\(idx)",
                    "type": "request",
                    "uri": "ssap://system/turnOff"
                ]
                let offData = try JSONSerialization.data(withJSONObject: turnOffPacket)
                if let offStr = String(data: offData, encoding: .utf8) {
                    try? await wsTask.send(.string(offStr))
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }

            wsTask.cancel(with: .normalClosure, reason: nil)
            return (true, "Rafale d'extinction envoyée à \(tv.name) (LG webOS).")
        } catch {
            wsTask.cancel(with: .goingAway, reason: nil)
            return (false, "TV LG hors ligne.")
        }
    }

    // MARK: - 3. Rafale Roku / TCL / Hisense (ECP port 8060)

    private func burstTurnOffRoku(tv: SmartTV) async -> (Bool, String) {
        let endpoints = [
            "http://\(tv.ipAddress):8060/keypress/PowerOff",
            "http://\(tv.ipAddress):8060/keypress/PowerOff",
            "http://\(tv.ipAddress):8060/keypress/Power"
        ]

        return await withTaskGroup(of: Bool.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    guard let url = URL(string: endpoint) else { return false }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 2.5
                    if let (_, response) = try? await URLSession.shared.data(for: req),
                       let http = response as? HTTPURLResponse,
                       (200...299).contains(http.statusCode) {
                        return true
                    }
                    return false
                }
            }
            var ok = false
            for await res in group where res {
                ok = true
            }
            return ok
                ? (true, "Rafale d'extinction envoyée à \(tv.name) (Roku).")
                : (false, "Échec de l'envoi Roku ECP vers \(tv.ipAddress).")
        }
    }

    // MARK: - 4. Rafale Sony Bravia (JSON-RPC + IRCC-IP simultanés)

    private func burstTurnOffSonyBravia(tv: SmartTV) async -> (Bool, String) {
        let psk = (tv.pairingToken?.isEmpty == false) ? tv.pairingToken! : "0000"

        return await withTaskGroup(of: Bool.self) { group in
            // Requête 1 & 2 : JSON-RPC setPowerStatus false
            for id in 1...2 {
                group.addTask {
                    guard let url = URL(string: "http://\(tv.ipAddress)/sony/system") else { return false }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 2.5
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(psk, forHTTPHeaderField: "X-Auth-PSK")
                    let body: [String: Any] = [
                        "method": "setPowerStatus",
                        "id": id,
                        "params": [["status": false]],
                        "version": "1.0"
                    ]
                    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                    if let (_, response) = try? await URLSession.shared.data(for: req),
                       let http = response as? HTTPURLResponse,
                       (200...299).contains(http.statusCode) {
                        return true
                    }
                    return false
                }
            }

            // Requête 3 : IRCC-IP SOAP PowerOff (AAAAAQAAAAEAAAAvAw==)
            group.addTask {
                guard let irccURL = URL(string: "http://\(tv.ipAddress)/sony/ircc") else { return false }
                var req = URLRequest(url: irccURL)
                req.httpMethod = "POST"
                req.timeoutInterval = 2.5
                req.setValue("text/xml; charset=UTF-8", forHTTPHeaderField: "Content-Type")
                req.setValue("\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\"", forHTTPHeaderField: "SOAPACTION")
                req.setValue(psk, forHTTPHeaderField: "X-Auth-PSK")
                let soap = """
                <?xml version="1.0"?>
                <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                  <s:Body>
                    <u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1">
                      <IRCCCode>AAAAAQAAAAEAAAAvAw==</IRCCCode>
                    </u:X_SendIRCC>
                  </s:Body>
                </s:Envelope>
                """
                req.httpBody = soap.data(using: .utf8)
                if let (_, response) = try? await URLSession.shared.data(for: req),
                   let http = response as? HTTPURLResponse,
                   (200...299).contains(http.statusCode) {
                    return true
                }
                return false
            }

            var ok = false
            for await res in group where res {
                ok = true
            }
            return ok
                ? (true, "Rafale d'extinction envoyée à \(tv.name) (Sony Bravia).")
                : (false, "Impossible d'éteindre \(tv.name) (Sony Bravia).")
        }
    }

    // MARK: - 5. Rafale Philips JointSpace (ports 1925 & 1926 simultanés)

    private func burstTurnOffPhilips(tv: SmartTV) async -> (Bool, String) {
        let urls = [
            "http://\(tv.ipAddress):1925/6/input/key",
            "https://\(tv.ipAddress):1926/6/input/key",
            "http://\(tv.ipAddress):1925/1/input/key"
        ]

        return await withTaskGroup(of: Bool.self) { group in
            for urlStr in urls {
                group.addTask {
                    guard let url = URL(string: urlStr) else { return false }
                    let delegate = InsecureTLSURLSessionDelegate()
                    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 2.5
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = Data("{\"key\":\"Standby\"}".utf8)
                    if let (_, response) = try? await session.data(for: req),
                       let http = response as? HTTPURLResponse,
                       (200...299).contains(http.statusCode) {
                        return true
                    }
                    return false
                }
            }

            var ok = false
            for await res in group where res {
                ok = true
            }
            return ok
                ? (true, "Rafale Standby envoyée à \(tv.name) (Philips).")
                : (false, "Impossible de joindre la TV Philips sur \(tv.ipAddress).")
        }
    }

    // MARK: - 6. Rafale Android TV / Google TV / Fire TV

    private func burstTurnOffAndroidTV(tv: SmartTV) async -> (Bool, String) {
        let adbPaths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        if let adbBin = adbPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let target = "\(tv.ipAddress):\(tv.port)"
            let ok = await Task.detached { () -> Bool in
                let connectProc = Process()
                connectProc.executableURL = URL(fileURLWithPath: adbBin)
                connectProc.arguments = ["connect", target]
                try? connectProc.run()
                connectProc.waitUntilExit()

                // Envoi répété de KEYCODE_SLEEP (223)
                for _ in 1...3 {
                    let sleepProc = Process()
                    sleepProc.executableURL = URL(fileURLWithPath: adbBin)
                    sleepProc.arguments = ["-s", target, "shell", "input", "keyevent", "223"]
                    try? sleepProc.run()
                    sleepProc.waitUntilExit()
                    if sleepProc.terminationStatus == 0 { return true }
                }
                return false
            }.value

            if ok {
                return (true, "Rafale de mise en veille ADB envoyée à \(tv.name).")
            }
        }

        // Essai parallèle des API constructeurs
        return await withTaskGroup(of: (Bool, String).self) { group in
            group.addTask { await self.burstTurnOffSonyBravia(tv: tv) }
            group.addTask { await self.burstTurnOffRoku(tv: tv) }
            group.addTask { await self.burstTurnOffPhilips(tv: tv) }
            for await res in group where res.0 {
                return res
            }
            return (false, "Impossible d'éteindre \(tv.name) (\(tv.ipAddress)).")
        }
    }

    // MARK: - 7. Webhook HTTP Personnalisé (Rafale x3)

    private func triggerCustomWebhook(tv: SmartTV) async -> (Bool, String) {
        let urlString = tv.customEndpointURL ?? "http://\(tv.ipAddress):\(tv.port)/poweroff"
        guard let url = URL(string: urlString) else {
            return (false, "URL de Webhook invalide : \(urlString)")
        }

        var succeeded = false
        for _ in 1...3 {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 3.0
            if let token = tv.pairingToken, !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let (_, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                succeeded = true
            }
        }

        return succeeded
            ? (true, "Rafale Webhook envoyée pour \(tv.name).")
            : (false, "Erreur réseau Webhook.")
    }
}

private final class InsecureTLSURLSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
