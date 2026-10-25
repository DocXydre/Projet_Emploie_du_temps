// Dessine l'icône de l'appli, l'orbe de HAL, dans chaque duo de couleurs (THM-3).
//
//   swift outils/icones_duos.swift
//
// Écrit ios/HAL/HAL/Assets.xcassets/AppIcon*.appiconset : AppIcon pour le duo
// d'origine (corail et ambre), AppIcon-<Duo> pour les autres. Les couleurs sont
// celles de `Combinaison.duo` dans Apparence.swift : à changer des deux côtés.

import AppKit
import CoreGraphics

let duos: [(nom: String, principal: UInt32, secondaire: UInt32)] = [
    ("AppIcon", 0xFF7A6B, 0xFFB547),
    ("AppIcon-RosePrune", 0xFF8FB8, 0xC183E8),
    ("AppIcon-ForetCitron", 0x7CD992, 0xE5E36B),
    ("AppIcon-MentheLilas", 0x5CE1C5, 0x9E94FF),
    ("AppIcon-OceanIndigo", 0x4FC3F7, 0x7B8CFF),
    ("AppIcon-NeigeArdoise", 0xF2F2F7, 0xAEB8C8),
]

func couleur(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Un mélange de deux couleurs, `part` de la seconde.
func melange(_ a: UInt32, _ b: UInt32, _ part: CGFloat) -> UInt32 {
    func canal(_ decalage: UInt32) -> UInt32 {
        let x = CGFloat((a >> decalage) & 0xFF), y = CGFloat((b >> decalage) & 0xFF)
        return UInt32((x + (y - x) * part).rounded()) << decalage
    }
    return canal(16) | canal(8) | canal(0)
}

func dessiner(principal: UInt32, secondaire: UInt32) -> Data {
    let cote = 1024
    let espace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: cote, height: cote, bitsPerComponent: 8, bytesPerRow: 0, space: espace,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let centre = CGPoint(x: 512, y: 512)

    // Le fond : une nuit, éclairée doucement par l'orbe.
    let nuit = CGGradient(colorsSpace: espace,
                          colors: [couleur(melange(0x2A2944, secondaire, 0.08)), couleur(0x0F0F1A)] as CFArray,
                          locations: [0, 1])!
    ctx.setFillColor(couleur(0x0F0F1A))
    ctx.fill(CGRect(x: 0, y: 0, width: cote, height: cote))
    ctx.drawRadialGradient(nuit, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 720, options: [])

    // L'anneau : la principale à droite, la secondaire à gauche.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 512 - 322, y: 512 - 322, width: 644, height: 644))
    ctx.clip()
    // Pas de dégradé conique dans CoreGraphics : des parts fines, une par demi-degré.
    let parts = 720
    for rang in 0..<parts {
        let debut = CGFloat(rang) / CGFloat(parts) * 2 * .pi
        let fin = CGFloat(rang + 1) / CGFloat(parts) * 2 * .pi + 0.004
        // 0 à droite, 1 à gauche, dans les deux sens.
        let part = (1 - cos((debut + fin) / 2)) / 2
        ctx.setFillColor(couleur(melange(principal, secondaire, part)))
        ctx.move(to: centre)
        ctx.addArc(center: centre, radius: 340, startAngle: debut, endAngle: fin, clockwise: false)
        ctx.closePath()
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Le cœur : blanc, qui prend la secondaire sur ses bords.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 512 - 159, y: 512 - 159, width: 318, height: 318))
    ctx.clip()
    let coeur = CGGradient(colorsSpace: espace,
                           colors: [couleur(0xFFFFFF), couleur(melange(0xFFFFFF, secondaire, 0.25)),
                                    couleur(melange(0xFFFFFF, secondaire, 0.6))] as CFArray,
                           locations: [0, 0.55, 1])!
    ctx.drawRadialGradient(coeur, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 159, options: [])
    ctx.restoreGState()

    let image = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

let catalogue = URL(fileURLWithPath: "ios/HAL/HAL/Assets.xcassets")
for duo in duos {
    let dossier = catalogue.appendingPathComponent("\(duo.nom).appiconset")
    try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
    try dessiner(principal: duo.principal, secondaire: duo.secondaire)
        .write(to: dossier.appendingPathComponent("AppIcon.png"))
    let contenu = """
    {
      "images" : [
        { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """
    try contenu.write(to: dossier.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("\(duo.nom) écrite")
}
