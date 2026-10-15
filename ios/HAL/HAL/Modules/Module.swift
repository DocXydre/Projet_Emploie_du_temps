import SwiftUI

/// Les trois tailles d'un widget (WID-2).
enum TailleWidget: String, Codable, CaseIterable, Identifiable {
    /// Un carré, la moitié de la largeur.
    case petit
    /// Toute la largeur, la hauteur d'un petit.
    case moyen
    /// Toute la largeur, deux fois la hauteur.
    case grand

    var id: String { rawValue }

    var libelle: String {
        switch self {
        case .petit: "Petit"
        case .moyen: "Moyen"
        case .grand: "Grand"
        }
    }
}

/// Une fonction de l'appli (WID-1). Elle déclare son widget, sa vue agrandie,
/// son écran complet si elle en a un, et ce que HAL peut en lire.
/// Pour en ajouter une : un fichier dans `Modules/Catalogue/`, et une ligne dans `Registre`.
struct Module: Identifiable {
    let id: String
    let nom: String
    let icone: String
    let categorie: Categorie
    /// Les tailles acceptées, la première étant celle par défaut.
    let tailles: [TailleWidget]
    /// Un module fixe ne se retire pas et ne se déplace pas (WID-7).
    var fixe = false
    let widget: @MainActor (TailleWidget) -> AnyView
    /// Ce qui s'affiche quand on touche le widget, sur place (WID-5).
    var agrandi: (@MainActor () -> AnyView)? = nil
    /// Un écran complet, ouvert à la place de la vue agrandie.
    var ecran: (@MainActor () -> AnyView)? = nil
    /// Ce que HAL lit de ce module quand il est à l'écran (ORB-3).
    var pourHAL: @MainActor (Foyer) -> String = { _ in "" }

    var tailleParDefaut: TailleWidget { tailles.first ?? .moyen }
}

/// Le cadre commun de tous les widgets : l'icône et le titre en haut, puis le contenu.
struct CoquilleWidget<Contenu: View>: View {
    let titre: String
    let icone: String
    let couleur: Color
    /// Un mot à droite de l'en-tête : « 1 sur 5 », « temps passé », « 30 jours ».
    var droite: String? = nil
    @ViewBuilder var contenu: Contenu
    @Environment(\.fermerAgrandi) private var fermerAgrandi

    var body: some View {
        VStack(alignment: .leading, spacing: Espace.serre) {
            HStack(spacing: 8) {
                Label(titre.uppercased(), systemImage: icone)
                    .texte(.etiquette)
                    .foregroundStyle(Palette.texteSecondaire)
                    .labelStyle(EtiquetteIcone(couleur: couleur))
                    .lineLimit(1)
                if let droite {
                    Spacer(minLength: 4)
                    Text(droite).texte(.legende).foregroundStyle(Palette.texteTertiaire).lineLimit(1)
                }
                if let fermerAgrandi {
                    Spacer(minLength: 4)
                    BoutonRond("xmark", libelle: "Fermer") { fermerAgrandi.fermer() }
                }
            }
            contenu
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .carte()
    }
}

extension CoquilleWidget {
    init(_ module: Module, droite: String? = nil, @ViewBuilder contenu: () -> Contenu) {
        self.init(titre: module.nom, icone: module.icone, couleur: module.categorie.couleur,
                  droite: droite, contenu: contenu)
    }
}
