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

    private(set) var photo: UIImage?
    private var couleursPhoto: Theme?

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
        photo = Self.lirePhoto()
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
    }

    private enum Cle {
        static let combinaison = "apparence.combinaison"
        static let couleursPhoto = "apparence.couleursPhoto"
        static let flou = "apparence.flou"
        static let assombrissement = "apparence.assombrissement"
        static let saturation = "apparence.saturation"
    }

    private static var fichierPhoto: URL {
        let dossier = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        return dossier.appendingPathComponent("fond.jpg")
    }

    private static func lirePhoto() -> UIImage? {
        guard let donnees = try? Data(contentsOf: fichierPhoto) else { return nil }
        return UIImage(data: donnees)
    }
}
