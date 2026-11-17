//
//  generate_dmg_background.swift
//  TvControl
//
//  Génère le fond Liquid Glass 24-bit Retina (640x440 @2x = 1280x880)
//  pour la fenêtre du DMG d'installation TvControl (identique à LaunchPad).
//

import AppKit

func generateDMGBackground() {
    let ptWidth: CGFloat = 640
    let ptHeight: CGFloat = 440
    let scale: Int = 2
    let pxWidth = Int(ptWidth) * scale
    let pxHeight = Int(ptHeight) * scale

    // Création d'un bitmap RGBA haute précision pour le dessin vectoriel
    let rgbaRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pxWidth,
        pixelsHigh: pxHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rgbaRep.size = NSSize(width: ptWidth, height: ptHeight)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rgbaRep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let cg = ctx.cgContext

    // Utilitaire de conversion Y (origine en haut comme SwiftUI -> origine en bas Quartz)
    func flipY(_ y: CGFloat, height: CGFloat = 0) -> CGFloat {
        ptHeight - y - height
    }

    // 1. Fond sombre solide (dégradé vertical identique à LaunchPad)
    let bgGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.17, alpha: 1.0),
        NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.11, alpha: 1.0)
    ])!
    bgGrad.draw(in: NSRect(x: 0, y: 0, width: ptWidth, height: ptHeight), angle: -90)

    // 2. Grille de points subtils
    let spacing: CGFloat = 28
    let dotSize: CGFloat = 1.6
    NSColor.white.withAlphaComponent(0.045).setFill()
    let cols = Int(ptWidth / spacing)
    let rows = Int(ptHeight / spacing)
    for col in 1..<cols {
        for row in 1..<rows {
            let x = CGFloat(col) * spacing - dotSize / 2
            let y = CGFloat(row) * spacing - dotSize / 2
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dotSize, height: dotSize)).fill()
        }
    }

    // 3. Bordure extérieure arrondie subtile
    let outerBorder = NSBezierPath(roundedRect: NSRect(x: 10, y: 10, width: ptWidth - 20, height: ptHeight - 20), xRadius: 18, yRadius: 18)
    outerBorder.lineWidth = 1.0
    NSColor.white.withAlphaComponent(0.09).setStroke()
    outerBorder.stroke()

    // 4. Fonction pour dessiner une carte Liquid Glass (175x175)
    func drawGlassCard(centerX: CGFloat, centerYTop: CGFloat) {
        let w: CGFloat = 175
        let h: CGFloat = 175
        let rect = NSRect(x: centerX - w / 2, y: flipY(centerYTop - h / 2, height: h), width: w, height: h)
        let path = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)

        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.32).cgColor)
        NSColor.white.withAlphaComponent(0.04).setFill()
        path.fill()
        cg.restoreGState()

        let cardGrad = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.08),
            NSColor.white.withAlphaComponent(0.02)
        ])!
        cardGrad.draw(in: path, angle: -45)

        path.lineWidth = 1.2
        NSColor.white.withAlphaComponent(0.22).setStroke()
        path.stroke()
    }

    // Carte gauche (TvControl.app à 175, 195) et Carte droite (Applications à 465, 195)
    drawGlassCard(centerX: 175, centerYTop: 195)
    drawGlassCard(centerX: 465, centerYTop: 195)

    // 5. Capsule centrale à chevrons (x: 320, yTop: 190)
    let arrowW: CGFloat = 76
    let arrowH: CGFloat = 36
    let arrowRect = NSRect(x: ptWidth / 2 - arrowW / 2, y: flipY(190 - arrowH / 2, height: arrowH), width: arrowW, height: arrowH)
    let arrowCapsule = NSBezierPath(roundedRect: arrowRect, xRadius: arrowH / 2, yRadius: arrowH / 2)
    NSColor.white.withAlphaComponent(0.05).setFill()
    arrowCapsule.fill()
    arrowCapsule.lineWidth = 1.0
    NSColor.white.withAlphaComponent(0.14).setStroke()
    arrowCapsule.stroke()

    let chevrons = NSAttributedString(
        string: "› › ›",
        attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.68, green: 0.48, blue: 0.98, alpha: 0.95)
        ]
    )
    let chevSize = chevrons.size()
    chevrons.draw(at: NSPoint(x: arrowRect.midX - chevSize.width / 2, y: arrowRect.midY - chevSize.height / 2 + 1))

    // 6. En-tête (Logo + TvControl + Sous-titre)
    let titleFont = NSFont.systemFont(ofSize: 20, weight: .bold)
    let titleStr = NSAttributedString(
        string: "TvControl",
        attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.white
        ]
    )
    let titleSize = titleStr.size()
    let headerY = flipY(34, height: titleSize.height)
    let titleX = ptWidth / 2 - titleSize.width / 2 + 12

    // Icône à gauche du titre
    if let iconImg = NSImage(contentsOfFile: "/tmp/tvcontrol_transparent_icon.png")
        ?? NSImage(contentsOfFile: "TvControl/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png") {
        iconImg.draw(in: NSRect(x: titleX - 30, y: headerY - 1, width: 24, height: 24))
    }

    titleStr.draw(at: NSPoint(x: titleX, y: headerY))

    let proGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.95, alpha: 1.0),
        NSColor(calibratedRed: 0.72, green: 0.38, blue: 0.98, alpha: 1.0)
    ])!

    // Sous-titre
    let subStr = NSAttributedString(
        string: "Minuteur d'extinction Wi-Fi pour votre TV dans la barre des menus",
        attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65)
        ]
    )
    let subSize = subStr.size()
    subStr.draw(at: NSPoint(x: ptWidth / 2 - subSize.width / 2, y: flipY(58, height: subSize.height)))

    // 7. Pilule d'instruction en bas (yTop: 340)
    let pillW: CGFloat = 350
    let pillH: CGFloat = 34
    let pillRect = NSRect(x: ptWidth / 2 - pillW / 2, y: flipY(340 - pillH / 2, height: pillH), width: pillW, height: pillH)
    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2)
    NSColor.white.withAlphaComponent(0.065).setFill()
    pillPath.fill()
    pillPath.lineWidth = 1.0
    NSColor.white.withAlphaComponent(0.18).setStroke()
    pillPath.stroke()

    // Petit cercle violet avec flèche à gauche de la pilule
    let circleRect = NSRect(x: pillRect.minX + 12, y: pillRect.midY - 10, width: 20, height: 20)
    let circlePath = NSBezierPath(ovalIn: circleRect)
    proGrad.draw(in: circlePath, angle: -45)

    let arrowSym = NSAttributedString(
        string: "→",
        attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white
        ]
    )
    let arrowSymSize = arrowSym.size()
    arrowSym.draw(at: NSPoint(x: circleRect.midX - arrowSymSize.width / 2, y: circleRect.midY - arrowSymSize.height / 2 + 0.5))

    let instrAttr = NSMutableAttributedString()
    let regularAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85)
    ]
    let boldAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .bold),
        .foregroundColor: NSColor.white
    ]
    instrAttr.append(NSAttributedString(string: "Glissez ", attributes: regularAttrs))
    instrAttr.append(NSAttributedString(string: "TvControl", attributes: boldAttrs))
    instrAttr.append(NSAttributedString(string: " dans le dossier ", attributes: regularAttrs))
    instrAttr.append(NSAttributedString(string: "Applications", attributes: boldAttrs))

    let instrSize = instrAttr.size()
    instrAttr.draw(at: NSPoint(x: circleRect.maxX + 10, y: pillRect.midY - instrSize.height / 2))

    NSGraphicsContext.restoreGraphicsState()

    // Conversion en Bitmap 24-bit RGB sans couche alpha (pour un affichage parfait dans Finder)
    let opaqueRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pxWidth,
        pixelsHigh: pxHeight,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: pxWidth * 3,
        bitsPerPixel: 24
    )!
    opaqueRep.size = NSSize(width: ptWidth, height: ptHeight)

    for y in 0..<pxHeight {
        for x in 0..<pxWidth {
            if let c = rgbaRep.colorAt(x: x, y: y) {
                opaqueRep.setColor(
                    NSColor(calibratedRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1.0),
                    atX: x,
                    y: y
                )
            }
        }
    }

    if let pngData = opaqueRep.representation(using: .png, properties: [:]) {
        let outURL = URL(fileURLWithPath: "/tmp/tvcontrol_bg_opaque.png")
        try? pngData.write(to: outURL)
        print("Fond DMG généré : /tmp/tvcontrol_bg_opaque.png (\(opaqueRep.pixelsWide)x\(opaqueRep.pixelsHigh))")
    }
}

generateDMGBackground()
