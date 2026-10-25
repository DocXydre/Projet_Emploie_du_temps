import SwiftUI

/// Les couleurs fixes de l'appli : textes et verre.
/// Elles ne changent pas avec la combinaison choisie, les catégories si (THM-3).
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

    /// Une nuance du duo choisi : toute l'appli suit la couleur (THM-3).
    var couleur: Color { Apparence.enVigueur.theme.couleur(self) }

    /// TAC-25 : la couleur d'un type de tâche. Celles que le serveur donne à sa
    /// création suivent le duo comme les familles, une couleur choisie reste.
    static func couleurDuType(_ hexa: String) -> Color? {
        switch hexa.uppercased() {
        case "#FFD166": Categorie.menage.couleur
        case "#B794F6": Categorie.linge.couleur
        case "#6FD3F2": Categorie.travail.couleur
        case "#FF9BCB": Categorie.chat.couleur
        case "#AEB8C8": Categorie.perso.couleur
        default: Color(hexa: hexa)
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
    /// TAC-25 : la couleur d'un type, telle que la base la garde : « #FF9BCB ».
    init?(hexa: String) {
        let chiffres = hexa.hasPrefix("#") ? String(hexa.dropFirst()) : hexa
        guard chiffres.count == 6, let valeur = UInt32(chiffres, radix: 16) else { return nil }
        self.init(hex: valeur)
    }

    /// L'inverse, pour l'envoyer : le sélecteur d'iOS rend n'importe quelle teinte.
    var hexa: String {
        let c = UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let canal = { (x: CGFloat) in Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", canal(r), canal(g), canal(b))
    }

    /// Une couleur écrite comme dans la maquette : `Color(hex: 0x5CE1C5)`.
    init(hex: UInt32, opacite: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacite)
    }
}
