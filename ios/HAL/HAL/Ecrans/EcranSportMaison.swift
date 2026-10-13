import SwiftUI

/// Un widget posé à une place fixe, hors de la grille d'Aujourd'hui.
struct WidgetFixe: View {
    let module: Module
    var taille: TailleWidget? = nil

    var body: some View {
        let choisie = taille ?? module.tailleParDefaut
        module.widget(choisie)
            .aspectRatio(choisie == .moyen ? 2.07 : 1, contentMode: .fit)
            .frame(maxWidth: .infinity)
    }
}

/// L'onglet Sport, dans l'ordre fixe de la maquette (3.1, WID-4).
struct EcranSport: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        PageDefilante {
            EnTeteOnglet(surTitre: foyer.essais.pause ? "Pause jusqu'au 25 oct." : "Cette semaine", titre: "Sport") {}
                .padding(.bottom, 4)
            if foyer.essais.pause {
                BandeauEtat(icone: "pause", titre: "HAL est en pause · examens",
                            detail: "jusqu'au dim. 25 oct. · récap un soir sur trois",
                            categorie: .ia, bouton: "Reprendre") { foyer.essais.pause = false }
            }
            WidgetFixe(module: .forme)
            HStack(spacing: Espace.gouttiere) {
                WidgetFixe(module: .sport, taille: .petit)
                WidgetFixe(module: .objectif)
            }
            WidgetFixe(module: .frequenceDuJour)
            HStack(spacing: Espace.gouttiere) {
                Color.clear.aspectRatio(1, contentMode: .fit)
                WidgetFixe(module: .seanceLibre)
            }
        }
    }
}

/// L'onglet Maison (4.1) : les tâches des deux, l'équilibre, le chat.
struct EcranMaison: View {
    @Environment(Foyer.self) private var foyer
    @State private var ajoutRapide = false

    var body: some View {
        PageDefilante {
            EnTeteOnglet(surTitre: ([foyer.moi.nom] + [foyer.autre?.nom].compactMap { $0 }).joined(separator: " et "),
                         titre: "Maison") {
                BoutonRond("plus", libelle: "Ajouter") { ajoutRapide = true }
            }
            .padding(.bottom, 4)
            WidgetFixe(module: .aCocher, taille: .moyen)
            HStack(spacing: Espace.gouttiere) {
                WidgetFixe(module: .chat)
                WidgetFixe(module: .equilibre)
            }
            HStack(spacing: Espace.gouttiere) {
                WidgetFixe(module: .enRetard)
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
        .sheet(isPresented: $ajoutRapide) { AjoutRapide().presentationDetents([.medium, .large]) }
    }
}

/// L'ajout rapide du « + » (APP-9). Tout se fait à la main, sans HAL.
struct AjoutRapide: View {
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer

    private let actions: [(String, String, Categorie)] = [
        ("Ajouter une tâche", "plus", .menage),
        ("C'est fait", "checkmark", .sport),
        ("Poser un créneau", "calendar.badge.plus", .travail),
        ("Une absence", "mappin", .ia),
        ("Une séance libre", "dumbbell", .sport),
        ("Une mesure", "scalemass", .linge),
        ("Mode allégé", "moon", .linge),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                BarreDeTitre(titre: "Ajouter") {
                    BoutonRond("xmark", libelle: "Fermer") { fermer() }
                }
                GroupeReglages {
                    ForEach(actions.indices, id: \.self) { rang in
                        let action = actions[rang]
                        Button {
                            fermer()
                            annoncer("« \(action.0) » arrive au lot 5")
                        } label: {
                            LigneReglage(icone: action.1, couleur: action.2.couleur, libelle: action.0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Espace.marge)
        }
        // Pas de fond à nous : la feuille d'iOS est en Liquid Glass, l'écran reste visible dessous.
        .scrollContentBackground(.hidden)
    }
}
