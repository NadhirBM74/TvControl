//
//  TVDiscoveryManager.swift
//  TvControl
//
//  Découverte multi-protocoles des Smart TV sur le réseau Wi-Fi local :
//  1. SSDP / UPnP Multicast (239.255.255.250:1900) + lecture XML UPnP
//  2. Bonjour / mDNS (_googlecast._tcp, _airplay._tcp, _hap._tcp, _adb._tcp)
//  3. Scan actif du sous-réseau Wi-Fi & table ARP sur les ports TV (Samsung 8001/8002, LG 3000/3001, Roku 8060, Sony 80, Android TV 5555/8008, Philips 1925)
//

import Foundation
import Network
import Combine
import Darwin

@MainActor
public final class TVDiscoveryManager: NSObject, ObservableObject {
    public static let shared = TVDiscoveryManager()

    @Published public private(set) var discoveredTVs: [SmartTV] = []
    @Published public var selectedTVID: String? {
        didSet {
            UserDefaults.standard.set(selectedTVID, forKey: Self.selectedTVKey)
        }
    }
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var localWiFiIP: String?

    private static let savedTVsKey = "TvControl.SavedSmartTVs"
    private static let selectedTVKey = "TvControl.SelectedSmartTVID"

    private var netServiceBrowsers: [NetServiceBrowser] = []
    private var resolvingServices: [NetService] = []
    private var scanTask: Task<Void, Never>?

    public var selectedTV: SmartTV? {
        if let id = selectedTVID, let match = discoveredTVs.first(where: { $0.id == id }) {
            return match
        }
        return discoveredTVs.first
    }

    override private init() {
        super.init()
        loadSavedTVs()
        self.selectedTVID = UserDefaults.standard.string(forKey: Self.selectedTVKey)
        if self.selectedTVID == nil, let first = discoveredTVs.first {
            self.selectedTVID = first.id
        }
        self.localWiFiIP = Self.detectLocalIPv4()
    }

    // MARK: - Persistance

    private func loadSavedTVs() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedTVsKey),
              let decoded = try? JSONDecoder().decode([SmartTV].self, from: data) else {
            return
        }
        self.discoveredTVs = decoded
    }

    public func saveTVs() {
        if let data = try? JSONEncoder().encode(discoveredTVs) {
            UserDefaults.standard.set(data, forKey: Self.savedTVsKey)
        }
    }

    public func selectTV(_ tv: SmartTV) {
        selectedTVID = tv.id
        if !discoveredTVs.contains(where: { $0.id == tv.id }) {
            discoveredTVs.append(tv)
        }
        saveTVs()
    }

    public func addOrUpdateTV(_ tv: SmartTV, autoSelect: Bool = false) {
        if let idx = discoveredTVs.firstIndex(where: { $0.id == tv.id || $0.ipAddress == tv.ipAddress }) {
            var updated = tv
            // Conserver le jeton d'appairage existant si le nouveau n'en a pas
            if updated.pairingToken == nil || updated.pairingToken?.isEmpty == true {
                updated.pairingToken = discoveredTVs[idx].pairingToken
            }
            let wasSelected = (selectedTVID == discoveredTVs[idx].id)
            discoveredTVs[idx] = updated
            if wasSelected || autoSelect || selectedTVID == nil {
                selectedTVID = updated.id
            }
        } else {
            discoveredTVs.append(tv)
            if autoSelect || selectedTVID == nil {
                selectedTVID = tv.id
            }
        }
        saveTVs()
    }

    public func updatePairingToken(for tvID: String, token: String) {
        guard let index = discoveredTVs.firstIndex(where: { $0.id == tvID }) else { return }
        discoveredTVs[index].pairingToken = token
        saveTVs()
    }

    public func removeTV(_ tv: SmartTV) {
        discoveredTVs.removeAll { $0.id == tv.id }
        if selectedTVID == tv.id {
            selectedTVID = discoveredTVs.first?.id
        }
        saveTVs()
    }

    // MARK: - Découverte Réseau Wi-Fi

    public func startScan() {
        guard !isScanning else { return }
        isScanning = true
        localWiFiIP = Self.detectLocalIPv4()

        // Démarrer la découverte Bonjour / mDNS sur le thread principal
        startBonjourDiscovery()

        scanTask?.cancel()
        scanTask = Task {
            await withTaskGroup(of: [SmartTV].self) { group in
                // 1. Découverte SSDP / UPnP Multicast
                group.addTask {
                    await Self.performSSDPScan()
                }

                // 2. Scan rapide des hôtes ARP + sous-réseau Wi-Fi sur les ports Smart TV
                group.addTask {
                    await Self.performSubnetAndARPScan(localIP: self.localWiFiIP)
                }

                for await foundBatch in group {
                    for tv in foundBatch {
                        self.addOrUpdateTV(tv)
                    }
                }
            }

            // Laisser Bonjour finir ses résolutions pendant 1 seconde supplémentaire
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.stopBonjourDiscovery()
            self.isScanning = false
        }
    }

    public func stopScan() {
        scanTask?.cancel()
        stopBonjourDiscovery()
        isScanning = false
    }

    // MARK: - 1. Bonjour / mDNS (_googlecast._tcp, _airplay._tcp, _hap._tcp)

    private func startBonjourDiscovery() {
        stopBonjourDiscovery()
        let serviceTypes = [
            "_googlecast._tcp.",
            "_airplay._tcp.",
            "_hap._tcp.",
            "_adb._tcp."
        ]

        for type in serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            netServiceBrowsers.append(browser)
        }
    }

    private func stopBonjourDiscovery() {
        for browser in netServiceBrowsers {
            browser.stop()
        }
        netServiceBrowsers.removeAll()
        resolvingServices.removeAll()
    }

    // MARK: - 2. SSDP / UPnP Multicast (239.255.255.250:1900)

    private nonisolated static func performSSDPScan() async -> [SmartTV] {
        let searchTargets = [
            "ssdp:all",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "urn:dial-multiscreen-org:service:dial:1",
            "urn:samsung.com:device:RemoteControlReceiver:1",
            "urn:lge-com:service:webos-second-screen:1",
            "roku:ecp"
        ]

        let rawResponses: [(ip: String, headers: [String: String])] = await Task.detached(priority: .userInitiated) {
            var collected: [(ip: String, headers: [String: String])] = []
            let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else { return collected }
            defer { close(sock) }

            var timeout = timeval(tv_sec: 0, tv_usec: 450_000)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var destAddr = sockaddr_in()
            destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destAddr.sin_family = sa_family_t(AF_INET)
            destAddr.sin_port = in_port_t(1900).bigEndian
            inet_pton(AF_INET, "239.255.255.250", &destAddr.sin_addr)

            for st in searchTargets {
                let packet = [
                    "M-SEARCH * HTTP/1.1",
                    "HOST: 239.255.255.250:1900",
                    "MAN: \"ssdp:discover\"",
                    "MX: 2",
                    "ST: \(st)",
                    "",
                    ""
                ].joined(separator: "\r\n")

                packet.withCString { ptr in
                    withUnsafePointer(to: &destAddr) { addrPtr in
                        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                            _ = sendto(sock, ptr, strlen(ptr), 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }

            let deadline = Date().addingTimeInterval(2.2)
            var buffer = [UInt8](repeating: 0, count: 4096)

            while Date() < deadline {
                var senderAddr = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        recvfrom(sock, &buffer, buffer.count - 1, 0, saPtr, &senderLen)
                    }
                }

                if bytesRead <= 0 {
                    continue
                }

                var ipCString = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addrCopy = senderAddr.sin_addr
                inet_ntop(AF_INET, &addrCopy, &ipCString, socklen_t(INET_ADDRSTRLEN))
                let senderIP = String(cString: ipCString)

                if let text = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                    var headers: [String: String] = [:]
                    for line in text.components(separatedBy: "\r\n") {
                        if let colon = line.firstIndex(of: ":") {
                            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
                            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                            headers[key] = value
                        }
                    }
                    collected.append((ip: senderIP, headers: headers))
                }
            }

            return collected
        }.value

        var tvsByIP: [String: SmartTV] = [:]

        for item in rawResponses {
            let ip = item.ip
            guard !ip.isEmpty, ip != "127.0.0.1" else { continue }
            let server = (item.headers["SERVER"] ?? "") + " " + (item.headers["ST"] ?? "") + " " + (item.headers["USN"] ?? "")
            let location = item.headers["LOCATION"]

            // Inspecter l'XML UPnP si disponible
            if let locStr = location, let locURL = URL(string: locStr) {
                if let tv = await Self.inspectUPnPDescription(url: locURL, fallbackIP: ip, serverHeader: server) {
                    tvsByIP[ip] = tv
                    continue
                }
            }

            // Classification par en-tête SSDP
            let lower = server.lowercased()
            if lower.contains("samsung") || lower.contains("tizen") {
                tvsByIP[ip] = SmartTV(name: "Samsung Smart TV", ipAddress: ip, brand: .samsung, isOnline: true)
            } else if lower.contains("webos") || lower.contains("lge") || lower.contains("lg ") {
                tvsByIP[ip] = SmartTV(name: "LG webOS TV", ipAddress: ip, brand: .lgWebOS, isOnline: true)
            } else if lower.contains("roku") {
                tvsByIP[ip] = SmartTV(name: "Roku TV", ipAddress: ip, brand: .roku, isOnline: true)
            } else if lower.contains("bravia") || lower.contains("sony") {
                tvsByIP[ip] = SmartTV(name: "Sony Bravia TV", ipAddress: ip, brand: .sonyBravia, isOnline: true)
            } else if lower.contains("philips") {
                tvsByIP[ip] = SmartTV(name: "Philips Smart TV", ipAddress: ip, brand: .philips, isOnline: true)
            }
        }

        return Array(tvsByIP.values)
    }

    private nonisolated static func inspectUPnPDescription(url: URL, fallbackIP: String, serverHeader: String) async -> SmartTV? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.8
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let xml = String(data: data, encoding: .utf8) else {
            return nil
        }

        let friendlyName = extractXMLTag("friendlyName", from: xml) ?? "Smart TV"
        let manufacturer = extractXMLTag("manufacturer", from: xml) ?? ""
        let modelName = extractXMLTag("modelName", from: xml) ?? ""
        let combined = "\(friendlyName) \(manufacturer) \(modelName) \(serverHeader)".lowercased()

        // Filtrer les routeurs / passerelles Internet qui ne sont pas des TV
        if combined.contains("internetgatewaydevice") || combined.contains("wanconnection") || combined.contains("router") || combined.contains("livebox") || combined.contains("bbox") {
            if !combined.contains("tv") && !combined.contains("player") && !combined.contains("cast") {
                return nil
            }
        }

        let ip = url.host ?? fallbackIP
        let brand: TVBrand
        if combined.contains("samsung") || combined.contains("tizen") {
            brand = .samsung
        } else if combined.contains("lg") || combined.contains("webos") {
            brand = .lgWebOS
        } else if combined.contains("roku") || combined.contains("tcl") || combined.contains("hisense") {
            brand = .roku
        } else if combined.contains("sony") || combined.contains("bravia") {
            brand = .sonyBravia
        } else if combined.contains("philips") {
            brand = .philips
        } else if combined.contains("android") || combined.contains("chromecast") || combined.contains("google") || combined.contains("xiaomi") || combined.contains("shield") {
            brand = .androidTV
        } else if combined.contains("tv") || combined.contains("mediarenderer") || combined.contains("dlna") {
            brand = .dlnaUPnP
        } else {
            return nil
        }

        return SmartTV(
            name: friendlyName,
            ipAddress: ip,
            brand: brand,
            modelName: modelName.isEmpty ? nil : modelName,
            isOnline: true,
            customEndpointURL: url.absoluteString
        )
    }

    // MARK: - 3. Scan Actif ARP + Sous-Réseau Wi-Fi

    private nonisolated static func performSubnetAndARPScan(localIP: String?) async -> [SmartTV] {
        var candidateIPs = Set<String>()

        // 1. Lire la table ARP macOS (/usr/sbin/arp -a) pour trouver instantanément les appareils actifs du Wi-Fi
        for ip in readARPTableIPs() {
            candidateIPs.insert(ip)
        }

        // 2. Ajouter les adresses du sous-réseau /24 si on connaît l'IP Wi-Fi locale
        if let localIP = localIP {
            let parts = localIP.split(separator: ".")
            if parts.count == 4 {
                let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
                for host in 1...254 {
                    let ip = "\(prefix).\(host)"
                    if ip != localIP {
                        candidateIPs.insert(ip)
                    }
                }
            }
        }

        let sortedCandidates = Array(candidateIPs)
        var discovered: [SmartTV] = []

        // Sonde les IP par lots pour rester rapide et léger
        let batchSize = 40
        for start in stride(from: 0, to: sortedCandidates.count, by: batchSize) {
            if Task.isCancelled { break }
            let end = min(start + batchSize, sortedCandidates.count)
            let slice = sortedCandidates[start..<end]

            let batchResults = await withTaskGroup(of: SmartTV?.self) { group -> [SmartTV] in
                for ip in slice {
                    group.addTask {
                        await probeHostForSmartTV(ip: ip)
                    }
                }
                var results: [SmartTV] = []
                for await res in group {
                    if let tv = res {
                        results.append(tv)
                    }
                }
                return results
            }
            discovered.append(contentsOf: batchResults)
        }

        return discovered
    }

    /// Teste les endpoints HTTP/TCP classiques des Smart TV sur une adresse IP locale.
    private nonisolated static func probeHostForSmartTV(ip: String) async -> SmartTV? {
        // 1. Samsung Smart TV API (port 8001)
        if await isTCPPortOpen(ip: ip, port: 8001, timeoutMs: 220) {
            if let samsungTV = await fetchSamsungMetadata(ip: ip) {
                return samsungTV
            }
            return SmartTV(name: "Samsung Smart TV (\(ip))", ipAddress: ip, port: 8002, brand: .samsung, isOnline: true)
        }

        // 2. LG webOS SSAP (port 3000 / 3001)
        if await isTCPPortOpen(ip: ip, port: 3000, timeoutMs: 220) {
            return SmartTV(name: "LG webOS TV (\(ip))", ipAddress: ip, port: 3000, brand: .lgWebOS, isOnline: true)
        }

        // 3. Roku / TCL / Hisense ECP (port 8060)
        if await isTCPPortOpen(ip: ip, port: 8060, timeoutMs: 220) {
            if let rokuTV = await fetchRokuMetadata(ip: ip) {
                return rokuTV
            }
            return SmartTV(name: "Roku TV (\(ip))", ipAddress: ip, port: 8060, brand: .roku, isOnline: true)
        }

        // 4. Google Cast / Android TV (port 8008 ou ADB 5555)
        if await isTCPPortOpen(ip: ip, port: 8008, timeoutMs: 220) {
            if let castTV = await fetchChromecastMetadata(ip: ip) {
                return castTV
            }
        }
        if await isTCPPortOpen(ip: ip, port: 5555, timeoutMs: 200) {
            return SmartTV(name: "Android TV (\(ip))", ipAddress: ip, port: 5555, brand: .androidTV, isOnline: true)
        }

        // 5. Philips JointSpace (port 1925)
        if await isTCPPortOpen(ip: ip, port: 1925, timeoutMs: 200) {
            return SmartTV(name: "Philips Smart TV (\(ip))", ipAddress: ip, port: 1925, brand: .philips, isOnline: true)
        }

        return nil
    }

    private nonisolated static func fetchSamsungMetadata(ip: String) async -> SmartTV? {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let device = json["device"] as? [String: Any]
        let name = (device?["name"] as? String) ?? (json["name"] as? String) ?? "Samsung Smart TV"
        let model = (device?["modelName"] as? String) ?? (device?["model"] as? String)
        let mac = device?["wifiMac"] as? String

        return SmartTV(
            name: name,
            ipAddress: ip,
            port: 8002,
            brand: .samsung,
            modelName: model,
            macAddress: mac,
            isOnline: true
        )
    }

    private nonisolated static func fetchRokuMetadata(ip: String) async -> SmartTV? {
        guard let url = URL(string: "http://\(ip):8060/query/device-info") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let xml = String(data: data, encoding: .utf8) else {
            return nil
        }
        let name = extractXMLTag("user-device-name", from: xml)
            ?? extractXMLTag("friendly-device-name", from: xml)
            ?? extractXMLTag("default-device-name", from: xml)
            ?? "Roku TV"
        let model = extractXMLTag("model-name", from: xml)
        let mac = extractXMLTag("wifi-mac", from: xml)

        return SmartTV(
            name: name,
            ipAddress: ip,
            port: 8060,
            brand: .roku,
            modelName: model,
            macAddress: mac,
            isOnline: true
        )
    }

    private nonisolated static func fetchChromecastMetadata(ip: String) async -> SmartTV? {
        guard let url = URL(string: "http://\(ip):8008/ssdp/device-desc.xml") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let xml = String(data: data, encoding: .utf8) else {
            return nil
        }
        let friendlyName = extractXMLTag("friendlyName", from: xml) ?? "Android TV"
        let model = extractXMLTag("modelName", from: xml)
        let manufacturer = (extractXMLTag("manufacturer", from: xml) ?? "").lowercased()

        let brand: TVBrand
        if manufacturer.contains("sony") {
            brand = .sonyBravia
        } else if manufacturer.contains("philips") {
            brand = .philips
        } else {
            brand = .androidTV
        }

        return SmartTV(
            name: friendlyName,
            ipAddress: ip,
            port: brand.defaultPort,
            brand: brand,
            modelName: model,
            isOnline: true
        )
    }

    // MARK: - Utilitaires Réseau Bas Niveau

    private nonisolated static func isTCPPortOpen(ip: String, port: UInt16, timeoutMs: Int32) async -> Bool {
        await Task.detached(priority: .utility) {
            let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard sock >= 0 else { return false }
            defer { close(sock) }

            let flags = fcntl(sock, F_GETFL, 0)
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

            let res = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    connect(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if res == 0 { return true }
            guard errno == EINPROGRESS else { return false }

            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pollRes = poll(&pfd, 1, timeoutMs)
            guard pollRes > 0 else { return false }

            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len)
            return soError == 0
        }.value
    }

    private nonisolated static func readARPTableIPs() -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        proc.arguments = ["-a"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            var ips: [String] = []
            for line in output.components(separatedBy: .newlines) {
                if let open = line.firstIndex(of: "("),
                   let close = line.firstIndex(of: ")"),
                   open < close {
                    let ip = String(line[line.index(after: open)..<close])
                    if !ip.hasSuffix(".255") && !ip.hasPrefix("224.") && !ip.hasPrefix("239.") {
                        ips.append(ip)
                    }
                }
            }
            return ips
        } catch {
            return []
        }
    }

    public nonisolated static func detectLocalIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    )
                    let ip = String(cString: hostname)
                    if !ip.isEmpty && !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                        address = ip
                        if name == "en0" { break }
                    }
                }
            }
        }
        return address
    }

    private nonisolated static func extractXMLTag(_ tag: String, from xml: String) -> String? {
        guard let startRange = xml.range(of: "<\(tag)>", options: .caseInsensitive),
              let endRange = xml.range(of: "</\(tag)>", options: .caseInsensitive, range: startRange.upperBound..<xml.endIndex) else {
            return nil
        }
        let raw = String(xml[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

// MARK: - NetServiceBrowserDelegate & NetServiceDelegate (Bonjour / mDNS)

extension TVDiscoveryManager: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            service.delegate = self
            self.resolvingServices.append(service)
            service.resolve(withTimeout: 3.0)
        }
    }

    nonisolated public func netServiceDidResolveAddress(_ sender: NetService) {
        let serviceName = sender.name
        let serviceType = sender.type
        let txtData = sender.txtRecordData()
        let addresses = sender.addresses ?? []

        var resolvedIP: String?
        for addrData in addresses {
            addrData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
                guard let base = rawBuffer.baseAddress else { return }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                if sa.pointee.sa_family == sa_family_t(AF_INET) {
                    let sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                    var addr = sin.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: buf)
                    if !ip.isEmpty && !ip.hasPrefix("127.") {
                        resolvedIP = ip
                    }
                }
            }
            if resolvedIP != nil { break }
        }

        guard let ip = resolvedIP else { return }

        var txtDict: [String: String] = [:]
        if let txtData = txtData {
            let rawDict = NetService.dictionary(fromTXTRecord: txtData)
            for (k, v) in rawDict {
                if let str = String(data: v, encoding: .utf8) {
                    txtDict[k] = str
                }
            }
        }

        let friendlyName = txtDict["fn"] ?? serviceName
        let model = txtDict["md"] ?? txtDict["model"] ?? ""
        let combined = "\(friendlyName) \(model) \(serviceType)".lowercased()

        // Ignorer ce Mac lui-même
        if ip == Self.detectLocalIPv4() { return }

        let brand: TVBrand
        if combined.contains("samsung") || combined.contains("tizen") {
            brand = .samsung
        } else if combined.contains("lg") || combined.contains("webos") {
            brand = .lgWebOS
        } else if combined.contains("roku") || combined.contains("tcl") || combined.contains("hisense") {
            brand = .roku
        } else if combined.contains("sony") || combined.contains("bravia") {
            brand = .sonyBravia
        } else if combined.contains("philips") {
            brand = .philips
        } else if serviceType.contains("_googlecast") || serviceType.contains("_adb") {
            brand = .androidTV
        } else if combined.contains("appletv") || combined.contains("apple tv") {
            brand = .appleTV
        } else if combined.contains("tv") {
            brand = .dlnaUPnP
        } else {
            return
        }

        Task { @MainActor in
            let tv = SmartTV(
                name: friendlyName,
                ipAddress: ip,
                port: brand.defaultPort,
                brand: brand,
                modelName: model.isEmpty ? nil : model,
                isOnline: true
            )
            self.addOrUpdateTV(tv)
        }
    }
}
