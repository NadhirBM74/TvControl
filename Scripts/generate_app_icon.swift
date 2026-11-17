//
//  generate_app_icon.swift
//  TvControl
//
//  Génère l'icône macOS Liquid Glass de TvControl en toutes les résolutions (16px à 1024px)
//  via Quartz 2D CPU (sans dépendance Metal/IOSurface).
//

import AppKit

func renderMasterIcon(size: CGFloat = 1024) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let cg = ctx.cgContext

    // 1. Squircle macOS (824x824 centré dans 1024x1024)
    let margin: CGFloat = 100
    let boxSize: CGFloat = size - margin * 2
    let squircleRect = NSRect(x: margin, y: margin, width: boxSize, height: boxSize)
    let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: 185, yRadius: 185)

    // Ombre portée du squircle
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.15, alpha: 1.0).setFill()
    squirclePath.fill()
    cg.restoreGState()

    // Dégradé principal sombre Liquid Glass
    squirclePath.addClip()
    let bgGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.28, alpha: 1.0),
        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.13, alpha: 1.0)
    ])!
    bgGradient.draw(in: squircleRect, angle: -55)

    // Halo lumineux violet/indigo au centre
    let glowGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.52, green: 0.34, blue: 0.98, alpha: 0.42),
        NSColor(calibratedRed: 0.35, green: 0.22, blue: 0.85, alpha: 0.12),
        NSColor.clear
    ])!
    glowGradient.draw(
        fromCenter: NSPoint(x: size / 2, y: size / 2 + 20),
        radius: 20,
        toCenter: NSPoint(x: size / 2, y: size / 2),
        radius: 360,
        options: []
    )

    // 2. Dessin de l'écran TV stylisé (cadre + écran intérieur + pied)
    let tvWidth: CGFloat = 490
    let tvHeight: CGFloat = 330
    let tvRect = NSRect(x: (size - tvWidth) / 2, y: (size - tvHeight) / 2 + 28, width: tvWidth, height: tvHeight)
    let tvOuterPath = NSBezierPath(roundedRect: tvRect, xRadius: 38, yRadius: 38)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    let frameGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.95, green: 0.96, blue: 1.0, alpha: 0.96),
        NSColor(calibratedRed: 0.72, green: 0.76, blue: 0.90, alpha: 0.92)
    ])!
    frameGrad.draw(in: tvOuterPath, angle: -90)
    cg.restoreGState()

    // Écran intérieur de la TV
    let screenInset: CGFloat = 22
    let screenRect = tvRect.insetBy(dx: screenInset, dy: screenInset)
    let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 22, yRadius: 22)
    let screenGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.26, alpha: 1.0),
        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.14, alpha: 1.0)
    ])!
    screenGrad.draw(in: screenPath, angle: -70)

    // Pied de la TV
    let standNeckRect = NSRect(x: (size - 56) / 2, y: tvRect.minY - 38, width: 56, height: 40)
    NSColor(calibratedRed: 0.78, green: 0.82, blue: 0.94, alpha: 0.9).setFill()
    NSBezierPath(rect: standNeckRect).fill()

    let standBaseRect = NSRect(x: (size - 210) / 2, y: tvRect.minY - 54, width: 210, height: 22)
    let standBasePath = NSBezierPath(roundedRect: standBaseRect, xRadius: 11, yRadius: 11)
    frameGrad.draw(in: standBasePath, angle: 0)

    // 3. Symbole Lune + Zzz / Minuteur doré au centre de l'écran TV
    if let moonBase = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 135, weight: .bold)
        if let configured = moonBase.withSymbolConfiguration(config) {
            let symSize = configured.size
            let symRect = NSRect(
                x: screenRect.midX - symSize.width / 2,
                y: screenRect.midY - symSize.height / 2,
                width: symSize.width,
                height: symSize.height
            )

            // Rendu teinté ambre/or
            let symRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(symSize.width * 2),
                pixelsHigh: Int(symSize.height * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            symRep.size = symSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: symRep)
            configured.draw(in: NSRect(origin: .zero, size: symSize))
            NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.25, alpha: 1.0).setFill()
            NSRect(origin: .zero, size: symSize).fill(using: .sourceIn)
            NSGraphicsContext.restoreGraphicsState()

            let tintedImg = NSImage(size: symSize)
            tintedImg.addRepresentation(symRep)

            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -4), blur: 16, color: NSColor.orange.withAlphaComponent(0.55).cgColor)
            tintedImg.draw(in: symRect)
            cg.restoreGState()
        }
    }

    // 4. Bordure spéculaire Liquid Glass sur le squircle
    let borderPath = NSBezierPath(roundedRect: squircleRect.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
    borderPath.lineWidth = 6
    NSColor.white.withAlphaComponent(0.24).setStroke()
    borderPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "TvControl/Assets.xcassets/AppIcon.appiconset"

let masterRep = renderMasterIcon(size: 1024)
let masterImg = NSImage(size: NSSize(width: 1024, height: 1024))
masterImg.addRepresentation(masterRep)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: s,
        pixelsHigh: s,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    masterImg.draw(
        in: NSRect(x: 0, y: 0, width: s, height: s),
        from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(s)x\(s).png"))
        if s == 1024 {
            try? png.write(to: URL(fileURLWithPath: "/tmp/tvcontrol_transparent_icon.png"))
        }
    }
}
print("Icônes générées avec succès dans \(outDir)")
