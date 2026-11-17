//
//  TVController.swift
//  TvControl
//
//  Moteur d'extinction et d'appairage Wi-Fi multi-marques pour Smart TV.
//  Supporte Samsung Tizen (WS/WSS), LG webOS (SSAP), Roku ECP, Sony Bravia (JSON-RPC/IRCC),
//  Philips JointSpace, Android TV (ADB Wi-Fi), UPnP/DLNA et Webhook personnalisé.
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

    /// Éteint la télévision passée en paramètre via le réseau Wi-Fi.
    public func turnOff(tv: SmartTV) async -> (success: Bool, message: String) {
        isSendingCommand = true
        lastStatusMessage = "Envoi du signal d'extinction à \(tv.name)..."
        lastCommandSucceeded = nil

        defer {
            isSendingCommand = false
        }

        let result: (Bool, String)
        switch tv.brand {
        case .samsung:
            result = await turnOffSamsung(tv: tv, pairOnly: false)
        case .lgWebOS:
            result = await turnOffLGWebOS(tv: tv, pairOnly: false)
        case .roku:
            result = await turnOffRoku(tv: tv)
        case .sonyBravia:
            result = await turnOffSonyBravia(tv: tv)
        case .philips:
            result = await turnOffPhilips(tv: tv)
        case .androidTV:
            result = await turnOffAndroidTV(tv: tv)
        case .appleTV:
            result = await turnOffAppleTVOrAirPlay(tv: tv)
        case .dlnaUPnP:
            result = await turnOffUPnP(tv: tv)
        case .customWebhook:
            result = await triggerCustomWebhook(tv: tv)
        }

        lastCommandSucceeded = result.0
        lastStatusMessage = result.1

        if result.0 {
            if UserDefaults.standard.object(forKey: "TvControl.SoundEnabled") == nil ||
               UserDefaults.standard.bool(forKey: "TvControl.SoundEnabled") {
                NSSound(named: "Blow")?.play()
            }
        } else {
            NSSound.beep()
        }

        return result
    }

    /// Associe (pair) la télévision sans l'éteindre immédiatement (ex: Samsung / LG webOS).
    public func pair(tv: SmartTV) async -> (success: Bool, message: String) {
        isSendingCommand = true
        lastStatusMessage = "Demande d'association envoyée à \(tv.name). Acceptez sur l'écran de la TV..."
        defer { isSendingCommand = false }

        let result: (Bool, String)
        switch tv.brand {
        case .samsung:
            result = await turnOffSamsung(tv: tv, pairOnly: true)
        case .lgWebOS:
            result = await turnOffLGWebOS(tv: tv, pairOnly: true)
        default:
            result = (true, "Aucun appairage préalable requis pour \(tv.brand.rawValue).")
        }

        lastCommandSucceeded = result.0
        lastStatusMessage = result.1
        return result
    }

    // MARK: - 1. Samsung Smart TV (Tizen WebSocket 8002 WSS / 8001 WS)

    private func turnOffSamsung(tv: SmartTV, pairOnly: Bool) async -> (Bool, String) {
        let appNameBase64 = Data("TvControl".utf8).base64EncodedString()
        var urlCandidates: [URL] = []

        var tokenQuery = ""
        if let token = tv.pairingToken, !token.isEmpty {
            tokenQuery = "&token=\(token)"
        }

        if let wssURL = URL(string: "wss://\(tv.ipAddress):8002/api/v2/channels/samsung.remote.control?name=\(appNameBase64)\(tokenQuery)") {
            urlCandidates.append(wssURL)
        }
        if let wsURL = URL(string: "ws://\(tv.ipAddress):8001/api/v2/channels/samsung.remote.control?name=\(appNameBase64)\(tokenQuery)") {
            urlCandidates.append(wsURL)
        }

        for wsURL in urlCandidates {
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
                        try await Task.sleep(nanoseconds: 12_000_000_000) // 12s pour laisser l'utilisateur accepter sur la TV
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
                        return (false, "Veuillez autoriser « TvControl » sur l'écran de votre TV Samsung avec votre télécommande.")
                    }
                }

                if pairOnly {
                    wsTask.cancel(with: .normalClosure, reason: nil)
                    return (true, "TV Samsung « \(tv.name) » associée avec succès !")
                }

                // Envoi de KEY_POWEROFF puis KEY_POWER pour compatibilité universelle Tizen
                for key in ["KEY_POWEROFF", "KEY_POWER"] {
                    let commandPayload: [String: Any] = [
                        "method": "ms.remote.control",
                        "params": [
                            "Cmd": "Click",
                            "DataOfCmd": key,
                            "Option": "false",
                            "TypeOfRemote": "SendRemoteKey"
                        ]
                    ]
                    if let cmdData = try? JSONSerialization.data(withJSONObject: commandPayload),
                       let cmdStr = String(data: cmdData, encoding: .utf8) {
                        try? await wsTask.send(.string(cmdStr))
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }

                wsTask.cancel(with: .normalClosure, reason: nil)
                return (true, "Signal d'extinction envoyé à \(tv.name) (Samsung).")
            } catch {
                wsTask.cancel(with: .goingAway, reason: nil)
                continue
            }
        }

        return (false, "Impossible de joindre \(tv.name) (\(tv.ipAddress)). Vérifiez que la TV est allumée sur le même Wi-Fi.")
    }

    // MARK: - 2. LG webOS TV (SSAP WebSocket port 3000 / 3001)

    private func turnOffLGWebOS(tv: SmartTV, pairOnly: Bool) async -> (Bool, String) {
        let urls = [
            URL(string: "ws://\(tv.ipAddress):3000"),
            URL(string: "wss://\(tv.ipAddress):3001")
        ].compactMap { $0 }

        for wsURL in urls {
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

                // Lire jusqu'à obtenir "registered" (peut d'abord recevoir une réponse "PROMPT" pendant que l'utilisateur clique Oui sur la TV)
                var isRegistered = false
                for _ in 0..<2 {
                    let msg = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                        group.addTask { try await wsTask.receive() }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 14_000_000_000)
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
                        } else if msgType == "error" {
                            wsTask.cancel(with: .goingAway, reason: nil)
                            return (false, "Association refusée sur l'écran de la TV LG.")
                        }
                    }
                }

                guard isRegistered else {
                    wsTask.cancel(with: .goingAway, reason: nil)
                    continue
                }

                if pairOnly {
                    wsTask.cancel(with: .normalClosure, reason: nil)
                    return (true, "TV LG webOS « \(tv.name) » associée avec succès !")
                }

                let turnOffPacket: [String: Any] = [
                    "id": "power_off_1",
                    "type": "request",
                    "uri": "ssap://system/turnOff"
                ]
                let offData = try JSONSerialization.data(withJSONObject: turnOffPacket)
                if let offStr = String(data: offData, encoding: .utf8) {
                    try await wsTask.send(.string(offStr))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }

                wsTask.cancel(with: .normalClosure, reason: nil)
                return (true, "Signal d'extinction envoyé à \(tv.name) (LG webOS).")
            } catch {
                wsTask.cancel(with: .goingAway, reason: nil)
                continue
            }
        }

        return (false, "Impossible de se connecter à la TV LG (\(tv.ipAddress)).")
    }

    // MARK: - 3. Roku / TCL / Hisense (ECP port 8060)

    private func turnOffRoku(tv: SmartTV) async -> (Bool, String) {
        let endpoints = [
            "http://\(tv.ipAddress):8060/keypress/PowerOff",
            "http://\(tv.ipAddress):8060/keypress/Power"
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 3.5

            if let (_, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                return (true, "Signal d'extinction envoyé à \(tv.name) (Roku ECP).")
            }
        }

        return (false, "Échec de l'envoi Roku ECP vers \(tv.ipAddress):8060.")
    }

    // MARK: - 4. Sony Bravia (JSON-RPC /sony/system + IRCC-IP)

    private func turnOffSonyBravia(tv: SmartTV) async -> (Bool, String) {
        let psk = (tv.pairingToken?.isEmpty == false) ? tv.pairingToken! : "0000"

        // 1. JSON-RPC REST API (/sony/system)
        if let url = URL(string: "http://\(tv.ipAddress)/sony/system") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 3.5
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(psk, forHTTPHeaderField: "X-Auth-PSK")
            let body: [String: Any] = [
                "method": "setPowerStatus",
                "id": 1,
                "params": [["status": false]],
                "version": "1.0"
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            if let (_, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                return (true, "Signal d'extinction envoyé à \(tv.name) (Sony Bravia).")
            }
        }

        // 2. Fallback Sony IRCC-IP SOAP (Code PowerOff = AAAAAQAAAAEAAAAvAw==)
        if let irccURL = URL(string: "http://\(tv.ipAddress)/sony/ircc") {
            var req = URLRequest(url: irccURL)
            req.httpMethod = "POST"
            req.timeoutInterval = 3.5
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
                return (true, "Signal IRCC d'extinction envoyé à \(tv.name) (Sony Bravia).")
            }
        }

        return (false, "Impossible d'éteindre \(tv.name). Vérifiez la clé pré-partagée (PSK) dans les paramètres.")
    }

    // MARK: - 5. Philips JointSpace (ports 1925 / 1926)

    private func turnOffPhilips(tv: SmartTV) async -> (Bool, String) {
        let urls = [
            "http://\(tv.ipAddress):1925/6/input/key",
            "https://\(tv.ipAddress):1926/6/input/key",
            "http://\(tv.ipAddress):1925/1/input/key"
        ]

        let delegate = InsecureTLSURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

        for urlStr in urls {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 3.5
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{\"key\":\"Standby\"}".utf8)

            if let (_, response) = try? await session.data(for: req),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                return (true, "Signal Standby envoyé à \(tv.name) (Philips).")
            }
        }

        return (false, "Impossible de joindre l'API Philips JointSpace sur \(tv.ipAddress).")
    }

    // MARK: - 6. Android TV / Google TV / Fire TV (ADB sur Wi-Fi port 5555)

    private func turnOffAndroidTV(tv: SmartTV) async -> (Bool, String) {
        let adbPaths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        if let adbBin = adbPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let target = "\(tv.ipAddress):\(tv.port)"
            let ok = await Task.detached { () -> Bool in
                let connectProc = Process()
                connectProc.executableURL = URL(fileURLWithPath: adbBin)
                connectProc.arguments = ["connect", target]
                try? connectProc.run()
                connectProc.waitUntilExit()

                let sleepProc = Process()
                sleepProc.executableURL = URL(fileURLWithPath: adbBin)
                // KEYCODE_SLEEP = 223 (éteint l'écran sans la rallumer si déjà éteinte) + KEYCODE_POWER = 26
                sleepProc.arguments = ["-s", target, "shell", "input", "keyevent", "223"]
                try? sleepProc.run()
                sleepProc.waitUntilExit()
                return sleepProc.terminationStatus == 0
            }.value

            if ok {
                return (true, "Signal de mise en veille ADB envoyé à \(tv.name).")
            }
        }

        // Essai de repli sur les protocoles Sony / Roku / Samsung au cas où la TV Android embarque l'API constructeur
        if let (ok, msg) = Optional(await turnOffSonyBravia(tv: tv)), ok { return (ok, msg) }
        if let (ok, msg) = Optional(await turnOffRoku(tv: tv)), ok { return (ok, msg) }
        if let (ok, msg) = Optional(await turnOffPhilips(tv: tv)), ok { return (ok, msg) }

        return (false, "Pour Android TV (\(tv.ipAddress)), activez le « Débogage ADB réseau » sur la TV ou installez `adb` (`brew install android-platform-tools`).")
    }

    // MARK: - 7. Apple TV / AirPlay

    private func turnOffAppleTVOrAirPlay(tv: SmartTV) async -> (Bool, String) {
        // Certaines Smart TV AirPlay 2 sont des Samsung, LG, Sony ou Roku : on tente leurs protocoles natifs !
        if let (ok, msg) = Optional(await turnOffSamsung(tv: tv, pairOnly: false)), ok { return (ok, msg) }
        if let (ok, msg) = Optional(await turnOffLGWebOS(tv: tv, pairOnly: false)), ok { return (ok, msg) }
        if let (ok, msg) = Optional(await turnOffRoku(tv: tv)), ok { return (ok, msg) }
        if let (ok, msg) = Optional(await turnOffSonyBravia(tv: tv)), ok { return (ok, msg) }

        return (false, "L'appareil AirPlay (\(tv.ipAddress)) ne répond pas aux commandes d'extinction standard. Choisissez la marque exacte de la TV dans les paramètres.")
    }

    // MARK: - 8. UPnP / DLNA Power Control

    private func turnOffUPnP(tv: SmartTV) async -> (Bool, String) {
        // Tenter d'abord les API constructeurs classiques sur la même IP
        if let (ok, msg) = Optional(await turnOffSamsung(tv: tv, pairOnly: false)), ok { return (ok, msg) }
        if let (ok, msg) = Optional(await turnOffLGWebOS(tv: tv, pairOnly: false)), ok { return (ok, msg) }
        if let (ok, msg) = Optional(await turnOffRoku(tv: tv)), ok { return (ok, msg) }
        if let (ok, msg) = Optional(await turnOffSonyBravia(tv: tv)), ok { return (ok, msg) }
        if let (ok, msg) = Optional(await turnOffPhilips(tv: tv)), ok { return (ok, msg) }

        return (false, "Impossible d'éteindre \(tv.name) via UPnP générique. Sélectionnez la marque de votre TV dans les paramètres.")
    }

    // MARK: - 9. Webhook HTTP Personnalisé (Home Assistant / Homebridge / Domotique)

    private func triggerCustomWebhook(tv: SmartTV) async -> (Bool, String) {
        let urlString = tv.customEndpointURL ?? "http://\(tv.ipAddress):\(tv.port)/poweroff"
        guard let url = URL(string: urlString) else {
            return (false, "URL de Webhook invalide : \(urlString)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5.0
        if let token = tv.pairingToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return (true, "Webhook d'extinction déclenché avec succès pour \(tv.name).")
            }
            // Fallback en GET
            req.httpMethod = "GET"
            let (_, getResp) = try await URLSession.shared.data(for: req)
            if let http = getResp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return (true, "Webhook d'extinction déclenché avec succès pour \(tv.name).")
            }
            return (false, "Le serveur Webhook a répondu avec une erreur.")
        } catch {
            return (false, "Erreur réseau Webhook : \(error.localizedDescription)")
        }
    }
}

/// Délégué URLSession acceptant les certificats TLS auto-signés locaux des téléviseurs (Samsung 8002, LG 3001, Philips 1926).
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
