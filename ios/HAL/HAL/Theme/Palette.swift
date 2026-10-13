import SwiftUI

/// Les couleurs fixes de l'appli : textes, verre, catégories.
/// Elles ne changent pas avec la combinaison choisie (THM-3).
enum Palette {
    static let textePrincipal = Color.white
    static let texteSecondaire = Color.white.opacity(0.72)
    static let texteTertiaire = Color.white.opacity(0.50)
    static let texteSurAccent = Color(hex: 0x0A0F14)

    static let verreTeinte = Color.white.opacity(0.08)
    static let verreTeinteForte = Color.white.opacity(0.16)
    static let verreBord = Color.white.opacity(0.24)
    static let verreSeparateur = Color.white.opacity(0.12)

    static let voileFond = Color.black.opacity(0.28)
    static let fondOrbe = Color(hex: 0x0D0F1A).opacity(0.70)
}

/// Une famille du planning, avec sa couleur.
enum Categorie: String, Codable, CaseIterable, Identifiable {
    case cours, travail, sport, menage, linge, chat, ia, alerte, perso

    var id: String { rawValue }

    var couleur: Color {
        switch self {
        case .cours: Color(hex: 0xFF8A65)
        case .travail: Color(hex: 0x7BB7FF)
        case .sport: Color(hex: 0x5CE1C5)
        case .menage: Color(hex: 0xFFD166)
        case .linge: Color(hex: 0xB794F6)
        case .chat: Color(hex: 0xFF9BCB)
        case .ia: Color(hex: 0x9E94FF)
        case .alerte: Color(hex: 0xFF6B61)
        case .perso: Color(hex: 0xAEB8C8)
        }
    }

    /// La même couleur en voile, pour les fonds de puces et de bandeaux.
    var voile: Color { couleur.opacity(0.26) }

    var libelle: String {
        switch self {
        case .cours: "Cours"
        case .travail: "Travail"
        case .sport: "Sport"
        case .menage: "Ménage"
        case .linge: "Linge"
        case .chat: "Chat"
        case .ia: "HAL"
        case .alerte: "Alerte"
        case .perso: "Perso"
        }
    }
}

extension Color {
    /// Une couleur écrite comme dans la maquette : `Color(hex: 0x5CE1C5)`.
    init(hex: UInt32, opacite: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacite)
    }
}
