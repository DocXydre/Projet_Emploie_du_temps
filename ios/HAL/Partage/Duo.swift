import SwiftUI

/// Une couleur en rouge, vert, bleu, de 0 à 1 : ce que l'appli et ses widgets
/// se passent par le dossier partagé.
struct RVB: Codable, Equatable, Sendable {
    var r: Double
    var v: Double
    var b: Double

    init(r: Double, v: Double, b: Double) {
        self.r = r
        self.v = v
        self.b = b
    }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255,
                  v: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255)
    }

    init(_ couleur: Color) {
        let c = UIColor(couleur).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, v: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &v, blue: &b, alpha: &a)
        self.init(r: min(max(r, 0), 1), v: min(max(v, 0), 1), b: min(max(b, 0), 1))
    }

    /// Teinte, saturation, luminosité, de 0 à 1.
    init(teinte: Double, saturation: Double, luminosite: Double) {
        let c = UIColor(hue: teinte - teinte.rounded(.down), saturation: min(max(saturation, 0), 1),
                        brightness: min(max(luminosite, 0), 1), alpha: 1)
        var r: CGFloat = 0, v: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &v, blue: &b, alpha: &a)
        self.init(r: r, v: v, b: b)
    }

    var tsl: (teinte: Double, saturation: Double, luminosite: Double) {
        var t: CGFloat = 0, s: CGFloat = 0, l: CGFloat = 0, a: CGFloat = 0
        UIColor(red: r, green: v, blue: b, alpha: 1).getHue(&t, saturation: &s, brightness: &l, alpha: &a)
        return (t, s, l)
    }

    var couleur: Color { Color(.sRGB, red: r, green: v, blue: b) }

    func distance(_ autre: RVB) -> Double {
        (r - autre.r) * (r - autre.r) + (v - autre.v) * (v - autre.v) + (b - autre.b) * (b - autre.b)
    }
}

/// Les deux couleurs choisies (THM-3). Toutes les catégories du planning en
/// sont des nuances, pour que l'appli entière suive le duo. Seule l'alerte
/// reste rouge : un retard doit se voir quel que soit le duo.
struct Duo: Codable, Equatable, Sendable {
    var principal: RVB
    var secondaire: RVB

    /// Corail et ambre, la couleur d'origine de l'appli.
    static let origine = Duo(principal: RVB(hex: 0xFF7A6B), secondaire: RVB(hex: 0xFFB547))
    static let alerte = RVB(hex: 0xFF6B61)

    /// La couleur d'une catégorie, par son nom côté serveur : `sport`, `cours`…
    func nuance(_ categorie: String) -> RVB {
        let p = principal.tsl, s = secondaire.tsl
        // L'écart de teinte le plus court, de la principale à la secondaire.
        var ecart = s.teinte - p.teinte
        if ecart > 0.5 { ecart -= 1 } else if ecart < -0.5 { ecart += 1 }
        let sens: Double = ecart < 0 ? -1 : 1
        switch categorie {
        case "sport": return principal
        case "ia": return secondaire
        case "travail":
            return RVB(teinte: p.teinte + ecart / 2, saturation: (p.saturation + s.saturation) / 2,
                       luminosite: (p.luminosite + s.luminosite) / 2)
        // Au-delà du duo, de part et d'autre, pour rester dans la même famille.
        case "cours": return RVB(teinte: p.teinte - sens * 0.05, saturation: p.saturation, luminosite: p.luminosite)
        case "chat": return RVB(teinte: s.teinte + sens * 0.05, saturation: s.saturation, luminosite: s.luminosite)
        // Les mêmes, pâlies.
        case "menage": return RVB(teinte: p.teinte, saturation: p.saturation * 0.5, luminosite: 1)
        case "linge": return RVB(teinte: s.teinte, saturation: s.saturation * 0.5, luminosite: 1)
        case "alerte": return Self.alerte
        default:
            return RVB(teinte: p.teinte + ecart / 2, saturation: min(0.18, p.saturation), luminosite: 0.8)
        }
    }

    private static let cle = "apparence.duoPartage"

    /// Le duo que l'appli a laissé aux widgets, celui d'origine sinon.
    static var enregistre: Duo {
        guard let donnees = UserDefaults(suiteName: Partage.groupe)?.data(forKey: cle),
              let duo = try? JSONDecoder().decode(Duo.self, from: donnees) else { return .origine }
        return duo
    }

    func enregistrer() {
        guard let donnees = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Partage.groupe)?.set(donnees, forKey: Self.cle)
    }
}
