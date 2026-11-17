//
//  SmartTV.swift
//  TvControl
//
//  Modèle représentant une Smart TV détectée ou configurée sur le réseau Wi-Fi local.
//

import Foundation
import AppKit

/// Marques et protocoles de Smart TV pris en charge sur le réseau Wi-Fi.
public enum TVBrand: String, Codable, CaseIterable, Identifiable {
    case samsung = "Samsung Tizen"
    case lgWebOS = "LG webOS"
    case roku = "Roku / TCL / Hisense"
    case sonyBravia = "Sony Bravia"
    case androidTV = "Android TV / Google TV"
    case philips = "Philips JointSpace"
    case appleTV = "Apple TV / AirPlay"
    case dlnaUPnP = "Smart TV (UPnP / DLNA)"
    case customWebhook = "Webhook HTTP personnalisé"

    public var id: String { rawValue }

    /// Port réseau par défaut selon le protocole de la TV.
    public var defaultPort: Int {
        switch self {
        case .samsung: return 8002
        case .lgWebOS: return 3000
        case .roku: return 8060
        case .sonyBravia: return 80
        case .androidTV: return 5555
        case .philips: return 1925
        case .appleTV: return 7000
        case .dlnaUPnP: return 1900
        case .customWebhook: return 80
        }
    }

    /// Symbole SF associé au téléviseur.
    public var symbolName: String {
        switch self {
        case .samsung, .lgWebOS, .sonyBravia, .philips:
            return "tv.fill"
        case .roku, .androidTV:
            return "tv.and.mediabox.fill"
        case .appleTV:
            return "appletv.fill"
        case .dlnaUPnP:
            return "tv"
        case .customWebhook:
            return "network"
        }
    }

    /// Courte description du protocole utilisé pour éteindre la TV.
    public var protocolSummary: String {
        switch self {
        case .samsung:
            return "WebSocket Samsung Remote (ports 8002/8001)"
        case .lgWebOS:
            return "LG SSAP WebSocket (ports 3000/3001)"
        case .roku:
            return "Roku ECP REST API (port 8060)"
        case .sonyBravia:
            return "Sony IRCC-IP / JSON-RPC (port 80)"
        case .androidTV:
            return "ADB Wi-Fi / Google Cast (port 5555)"
        case .philips:
            return "Philips JointSpace API (port 1925/1926)"
        case .appleTV:
            return "AirPlay / Companion Link"
        case .dlnaUPnP:
            return "UPnP / SOAP Power Control"
        case .customWebhook:
            return "Requête HTTP GET/POST personnalisée"
        }
    }

    /// Indique si le téléviseur peut demander une confirmation d'appairage à l'écran lors de la 1re connexion.
    public var supportsPairing: Bool {
        switch self {
        case .samsung, .lgWebOS, .sonyBravia, .androidTV:
            return true
        default:
            return false
        }
    }
}

/// Représente une télévision détectée sur le réseau Wi-Fi.
public struct SmartTV: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var ipAddress: String
    public var port: Int
    public var brand: TVBrand
    public var modelName: String?
    public var macAddress: String?
    public var isOnline: Bool
    /// Jeton d'association (Samsung token, LG client-key, ou Sony Pre-Shared Key PSK)
    public var pairingToken: String?
    /// URL optionnelle de contrôle UPnP ou Webhook personnalisé
    public var customEndpointURL: String?

    public init(
        id: String? = nil,
        name: String,
        ipAddress: String,
        port: Int? = nil,
        brand: TVBrand,
        modelName: String? = nil,
        macAddress: String? = nil,
        isOnline: Bool = true,
        pairingToken: String? = nil,
        customEndpointURL: String? = nil
    ) {
        self.id = id ?? "\(ipAddress)-\(brand.rawValue)"
        self.name = name
        self.ipAddress = ipAddress
        self.port = port ?? brand.defaultPort
        self.brand = brand
        self.modelName = modelName
        self.macAddress = macAddress
        self.isOnline = isOnline
        self.pairingToken = pairingToken
        self.customEndpointURL = customEndpointURL
    }

    public var subtitle: String {
        if let model = modelName, !model.isEmpty, model != name {
            return "\(model) • \(ipAddress)"
        }
        return "\(brand.rawValue) • \(ipAddress)"
    }
}

/// Préréglages de minuteur demandés (1h, 2h, 3h, 4h, 5h).
public enum TimerPreset: Int, CaseIterable, Identifiable {
    case oneHour = 1
    case twoHours = 2
    case threeHours = 3
    case fourHours = 4
    case fiveHours = 5

    public var id: Int { rawValue }

    public var hours: Int { rawValue }

    public var seconds: Int { rawValue * 3600 }

    public var title: String {
        switch self {
        case .oneHour: return "1 heure"
        case .twoHours: return "2 heures"
        case .threeHours: return "3 heures"
        case .fourHours: return "4 heures"
        case .fiveHours: return "5 heures"
        }
    }

    public var shortLabel: String {
        "\(rawValue)h"
    }

    public var subtitle: String {
        let target = Date().addingTimeInterval(TimeInterval(seconds))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "Extinction à \(formatter.string(from: target))"
    }
}
