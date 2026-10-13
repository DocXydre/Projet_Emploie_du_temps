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
    @Environment(Foyer.self) private var foyer

    private enum Action: String, CaseIterable, Identifiable {
        case tache = "Ajouter une tâche"
        case faite = "C'est fait"
        case creneau = "Poser un créneau"
        case absence = "Une absence"
        case seanceLibre = "Une séance libre"
        case mesure = "Une mesure"
        case allege = "Mode allégé"

        var id: String { rawValue }

        var icone: String {
            switch self {
            case .tache: "plus"
            case .faite: "checkmark"
            case .creneau: "calendar.badge.plus"
            case .absence: "mappin"
            case .seanceLibre: "dumbbell"
            case .mesure: "scalemass"
            case .allege: "moon"
            }
        }

        var categorie: Categorie {
            switch self {
            case .tache: .menage
            case .faite, .seanceLibre: .sport
            case .creneau: .travail
            case .absence: .ia
            case .mesure, .allege: .linge
            }
        }

        /// Ce qui arrive avec le sport, au lot 6.
        var plusTard: Bool { self == .seanceLibre || self == .mesure }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Action.allCases) { action in
                    if action.plusTard || !foyer.connecte {
                        Button {
                            fermer()
                            annoncer(action.plusTard ? "« \(action.rawValue) » arrive avec le sport"
                                                     : "Connecte-toi à ton serveur pour « \(action.rawValue) »")
                        } label: {
                            LigneReglage(icone: action.icone, couleur: action.categorie.couleur,
                                         libelle: action.rawValue)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: action) {
                            LigneReglage(icone: action.icone, couleur: action.categorie.couleur,
                                         libelle: action.rawValue, accessoire: .aucun)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Ajouter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer", systemImage: "xmark") { fermer() }
                }
            }
            .navigationDestination(for: Action.self) { action in
                switch action {
                case .tache: FormulaireTache()
                case .faite: FormulaireFaite()
                case .creneau: FormulaireCreneau()
                case .absence: FormulaireAbsence()
                case .allege: FormulaireAllege()
                case .seanceLibre, .mesure: EmptyView()
                }
            }
        }
        .environment(\.fermerFeuille, ActionFermer { fermer() })
        // Pas de fond à nous : la feuille d'iOS est en Liquid Glass, l'écran reste visible dessous.
    }
}
