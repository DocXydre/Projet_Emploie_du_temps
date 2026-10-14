import SwiftUI
import Observation

/// Les quatre combinaisons de couleurs des boutons, de l'orbe et des accents (THM-3).
enum Combinaison: String, CaseIterable, Identifiable, Codable {
    case mentheLilas, ambreCorail, oceanIndigo, neigeArdoise

    var id: String { rawValue }

    var nom: String {
        switch self {
        case .mentheLilas: "Menthe · Lilas"
        case .ambreCorail: "Ambre · Corail"
        case .oceanIndigo: "Océan · Indigo"
        case .neigeArdoise: "Neige · Ardoise"
        }
    }

    var principal: Color {
        switch self {
        case .mentheLilas: Color(hex: 0x5CE1C5)
        case .ambreCorail: Color(hex: 0xFFB547)
        case .oceanIndigo: Color(hex: 0x4FC3F7)
        case .neigeArdoise: Color(hex: 0xF2F2F7)
        }
    }

    var secondaire: Color {
        switch self {
        case .mentheLilas: Color(hex: 0x9E94FF)
        case .ambreCorail: Color(hex: 0xFF7A6B)
        case .oceanIndigo: Color(hex: 0x7B8CFF)
        case .neigeArdoise: Color(hex: 0xAEB8C8)
        }
    }
}

/// Les couleurs en vigueur, lues par tous les composants.
struct Theme: Equatable {
    var principal: Color
    var secondaire: Color

    var principalVoile: Color { principal.opacity(0.26) }
    var secondaireVoile: Color { secondaire.opacity(0.30) }
    /// Le texte posé sur un bouton plein.
    var surPrincipal: Color { Color(hex: 0x0A0D14) }

    init(_ combinaison: Combinaison) {
        principal = combinaison.principal
        secondaire = combinaison.secondaire
    }

    init(principal: Color, secondaire: Color) {
        self.principal = principal
        self.secondaire = secondaire
    }
}

private struct CleTheme: EnvironmentKey {
    static let defaultValue = Theme(.mentheLilas)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[CleTheme.self] }
        set { self[CleTheme.self] = newValue }
    }
}

/// Le verre des cartes et des widgets (THM-5). Réglage de l'appareil.
enum StyleVerre: String, CaseIterable, Identifiable, Codable {
    /// Le Liquid Glass d'iOS 26 : il réfracte la photo et reflète la lumière.
    case liquide
    /// Le même, plus transparent : la photo passe davantage.
    case liquideClair
    /// L'ancien verre : un flou uniforme, plus opaque, le plus lisible.
    case depoli

    var id: String { rawValue }

    var nom: String {
        switch self {
        case .liquide: "Liquid Glass"
        case .liquideClair: "Transparent"
        case .depoli: "Dépoli"
        }
    }

    var detail: String {
        switch self {
        case .liquide: "Le verre d'iOS : il réfracte la photo et reflète la lumière."
        case .liquideClair: "Le même verre, plus transparent : la photo passe davantage. À assombrir si le texte se lit mal."
        case .depoli: "Un flou uniforme, plus opaque : le plus lisible sur une photo chargée."
        }
    }
}

/// Ce que les cartes lisent pour se dessiner.
struct ReglageVerre: Equatable {
    var style: StyleVerre = .liquide
    /// De 0 à 0,6 : la teinte sombre posée dans le verre, pour la lisibilité.
    var teinte: Double = 0.15
}

extension EnvironmentValues {
    @Entry var verre = ReglageVerre()
}

/// L'apparence de l'appli : la photo de fond, son traitement et la combinaison.
/// C'est un réglage de l'appareil, il ne part pas au serveur (THM-6).
@Observable
final class Apparence {
    var combinaison: Combinaison { didSet { enregistrer() } }
    var couleursDeLaPhoto: Bool { didSet { enregistrer(); recalculerCouleursPhoto() } }
    /// De 0 à 1 : flou, assombrissement et désaturation de la photo (THM-2).
    var flou: Double { didSet { enregistrer() } }
    var assombrissement: Double { didSet { enregistrer() } }
    var saturation: Double { didSet { enregistrer() } }
    /// Le verre des cartes : Liquid Glass, transparent ou dépoli.
    var styleVerre: StyleVerre { didSet { enregistrer() } }
    var teinteVerre: Double { didSet { enregistrer() } }

    var verre: ReglageVerre { ReglageVerre(style: styleVerre, teinte: teinteVerre) }

    private(set) var photo: UIImage? {
        didSet { luminancePhoto = photo.map(Self.luminance) ?? 0 }
    }
    private var couleursPhoto: Theme?
    /// De 0 à 1 : la clarté moyenne de la photo choisie.
    private(set) var luminancePhoto: Double = 0

    /// THM-2 : l'assombrissement réellement posé sur la photo. Sur une photo
    /// claire, le réglage ne descend pas sous le voile qui garde le texte blanc
    /// lisible : le fond reste au plus à `clarteMaximale` une fois assombri.
    var assombrissementEffectif: Double { max(assombrissement, plancherAssombrissement) }

    /// Le voile minimal qu'impose la photo, 0 pour une photo sombre.
    var plancherAssombrissement: Double {
        guard luminancePhoto > Self.clarteMaximale else { return 0 }
        return min(0.7, 1 - Self.clarteMaximale / luminancePhoto)
    }

    private static let clarteMaximale = 0.34

    /// Les couleurs à appliquer, selon le réglage.
    var theme: Theme {
        if couleursDeLaPhoto, let couleursPhoto { return couleursPhoto }
        return Theme(combinaison)
    }

    private let reglages = UserDefaults.standard

    init() {
        combinaison = Combinaison(rawValue: reglages.string(forKey: Cle.combinaison) ?? "") ?? .mentheLilas
        couleursDeLaPhoto = reglages.bool(forKey: Cle.couleursPhoto)
        flou = reglages.object(forKey: Cle.flou) as? Double ?? 0.35
        assombrissement = reglages.object(forKey: Cle.assombrissement) as? Double ?? 0.28
        saturation = reglages.object(forKey: Cle.saturation) as? Double ?? 0.9
        styleVerre = StyleVerre(rawValue: reglages.string(forKey: Cle.styleVerre) ?? "") ?? .liquide
        teinteVerre = reglages.object(forKey: Cle.teinteVerre) as? Double ?? 0.15
        photo = Self.lirePhoto()
        luminancePhoto = photo.map(Self.luminance) ?? 0
        recalculerCouleursPhoto()
    }

    /// Remplace la photo de fond. `nil` revient à la photo par défaut.
    func changerPhoto(_ image: UIImage?) {
        photo = image
        if let image, let donnees = image.jpegData(compressionQuality: 0.9) {
            try? donnees.write(to: Self.fichierPhoto, options: .completeFileProtection)
        } else {
            try? FileManager.default.removeItem(at: Self.fichierPhoto)
        }
        recalculerCouleursPhoto()
    }

    func revenirAuxReglagesParDefaut() {
        flou = 0.35
        assombrissement = 0.28
        saturation = 0.9
        styleVerre = .liquide
        teinteVerre = 0.15
    }

    private func recalculerCouleursPhoto() {
        guard couleursDeLaPhoto, let photo else { couleursPhoto = nil; return }
        couleursPhoto = CouleursPhoto.theme(depuis: photo)
    }

    private func enregistrer() {
        reglages.set(combinaison.rawValue, forKey: Cle.combinaison)
        reglages.set(couleursDeLaPhoto, forKey: Cle.couleursPhoto)
        reglages.set(flou, forKey: Cle.flou)
        reglages.set(assombrissement, forKey: Cle.assombrissement)
        reglages.set(saturation, forKey: Cle.saturation)
        reglages.set(styleVerre.rawValue, forKey: Cle.styleVerre)
        reglages.set(teinteVerre, forKey: Cle.teinteVerre)
    }

    private enum Cle {
        static let combinaison = "apparence.combinaison"
        static let couleursPhoto = "apparence.couleursPhoto"
        static let flou = "apparence.flou"
        static let assombrissement = "apparence.assombrissement"
        static let saturation = "apparence.saturation"
        static let styleVerre = "apparence.styleVerre"
        static let teinteVerre = "apparence.teinteVerre"
    }

    private static var fichierPhoto: URL {
        let dossier = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        return dossier.appendingPathComponent("fond.jpg")
    }

    /// La clarté moyenne d'une image, sur une réduction à 16 × 16.
    private static func luminance(_ image: UIImage) -> Double {
        let cote = 16
        var pixels = [UInt8](repeating: 0, count: cote * cote * 4)
        guard let cg = image.cgImage,
              let contexte = CGContext(data: &pixels, width: cote, height: cote, bitsPerComponent: 8,
                                       bytesPerRow: cote * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        contexte.interpolationQuality = .medium
        contexte.draw(cg, in: CGRect(x: 0, y: 0, width: cote, height: cote))
        var somme = 0.0
        for rang in stride(from: 0, to: pixels.count, by: 4) {
            somme += 0.2126 * Double(pixels[rang]) + 0.7152 * Double(pixels[rang + 1])
                + 0.0722 * Double(pixels[rang + 2])
        }
        return somme / 255 / Double(cote * cote)
    }

    private static func lirePhoto() -> UIImage? {
        guard let donnees = try? Data(contentsOf: fichierPhoto) else { return nil }
        return UIImage(data: donnees)
    }
}
