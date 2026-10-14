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

/// L'onglet Sport, dans l'ordre fixe de la maquette (3.1, WID-4). Ce qui attend
/// une réponse passe devant : la séance en cours, celle du jour, une mesure, un
/// ajustement de HAL.
struct EcranSport: View {
    @Environment(Foyer.self) private var foyer
    @Environment(SeanceEnCours.self) private var seance
    @Environment(EnvoiSante.self) private var sante
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.annoncer) private var annoncer
    @State private var prevue: DetailSeance?
    @State private var annonce = false

    var body: some View {
        PageDefilante {
            EnTeteOnglet(surTitre: enPause ? "En pause" : "Cette semaine", titre: "Sport") {}
                .padding(.bottom, 4)
            if enPause {
                // PAU-1 : la pause se lève d'ici, ou depuis Réglages.
                BandeauEtat(icone: "pause", titre: "HAL est en pause",
                            detail: "Les séances se posent à la main ; le récap passe un soir sur trois",
                            categorie: .ia, bouton: foyer.connecte ? "Reprendre" : nil) {
                    Task {
                        do {
                            try await foyer.agir("DELETE", "coach/pause")
                            annoncer("Pause levée : HAL prépare la reprise")
                        } catch {
                            annoncer((error as? ErreurAPI)?.message ?? "Impossible pour l'instant")
                        }
                    }
                }
            }
            if let bloc = foyer.sportDuServeur?.demarrage {
                // DEM-1, 7.18 : le démarrage, ou sa reprise là où on s'était arrêté.
                Button { conversation.demarrageOuvert = true } label: {
                    BandeauEtat(icone: "sparkle",
                                titre: bloc == "profil" ? "Démarrer HAL" : "Reprendre le démarrage",
                                detail: bloc == "profil"
                                    ? "Quelques questions, et HAL te propose quatre semaines"
                                    : "Il reste : \(EcranDemarrage.nomDuBloc(bloc))",
                                categorie: .ia)
                }
                .buttonStyle(.plain)
            }
            if seance.enCours {
                BandeauEtat(icone: "dumbbell", titre: "Séance en cours",
                            detail: "\(seance.seance?.series.count ?? 0) séries · \(seance.minutesEcoulees) min",
                            categorie: .sport, bouton: "Reprendre") { seance.affichee = true }
            } else if let detail = foyer.seanceDuJour {
                WidgetFixe(module: .lancerSeance)
                    .onTapGesture { prevue = detail }
            }
            if let semaine = foyer.sportDuServeur?.semaineAValider {
                NavigationLink { EcranSemaine() } label: {
                    BandeauEtat(icone: "calendar.badge.checkmark", titre: "Semaine à valider",
                                detail: "\(semaine.seances) séance\(semaine.seances > 1 ? "s" : "") proposée\(semaine.seances > 1 ? "s" : "") par HAL",
                                categorie: .ia)
                }
                .buttonStyle(.plain)
            }
            ForEach(foyer.sportDuServeur?.invitations ?? []) { invitation in
                BandeauInvitation(invitation: invitation)
            }
            ForEach(foyer.sportDuServeur?.seancesDuJour.filter { !$0.close && $0.seance.discipline != "musculation" } ?? []) { course in
                Button { prevue = course } label: {
                    BandeauEtat(icone: "figure.run", titre: "\(course.titre) aujourd'hui",
                                detail: course.prevu.first?.consigne ?? course.seance.consigne ?? "Le détail de la séance",
                                categorie: .sport)
                }
                .buttonStyle(.plain)
            }
            if foyer.ajustement != nil { WidgetFixe(module: .ajustement) }
            if foyer.mesureDemandee != nil { WidgetFixe(module: .mesureDemandee) }
            lien(EcranSommeil()) { WidgetFixe(module: .forme) }
            HStack(spacing: Espace.gouttiere) {
                lien(EcranSemaine()) { WidgetFixe(module: .sport, taille: .petit) }
                lien(EcranObjectifs()) { WidgetFixe(module: .objectif) }
            }
            lien(EcranFrequence()) { WidgetFixe(module: .frequenceDuJour) }
            HStack(spacing: Espace.gouttiere) {
                Color.clear.aspectRatio(1, contentMode: .fit)
                WidgetFixe(module: .seanceLibre)
            }
            EnTeteGroupe(texte: "Aller plus loin")
            GroupeReglages {
                ligne("La semaine", "calendar", Categorie.sport.couleur) { EcranSemaine() }
                ligne("Progression", "chart.line.uptrend.xyaxis", Categorie.sport.couleur) { EcranProgression() }
                ligne("Sommeil et récupération", "bed.double", Categorie.linge.couleur) { EcranSommeil() }
                ligne("Objectifs", "target", Categorie.sport.couleur) { EcranObjectifs() }
                ligne("Mesures", "scalemass", Categorie.ia.couleur) { EcranMesures() }
                ligne("Séances de la montre", "applewatch", Categorie.sport.couleur) { EcranSeancesMontre() }
                ligne("Fréquence cardiaque du jour", "heart.text.square", Categorie.alerte.couleur) { EcranFrequence() }
                Button { annonce = true } label: {
                    LigneReglage(icone: "calendar.badge.plus", couleur: Categorie.ia.couleur,
                                 libelle: "Annoncer une séance libre")
                }
                .buttonStyle(.plain)
            }
            if let bilan = sante.dernierBilan {
                Text("Santé : \(bilan)").texte(.legende).foregroundStyle(Palette.texteTertiaire)
            }
        }
        .refreshable {
            await foyer.charger()
            await sante.envoyer(raison: "à la demande")
            foyer.poserLaFrequence(sante.frequenceDuJour)
        }
        .sheet(item: $prevue) { detail in EcranSeancePrevue(detail: detail) }
        .sheet(isPresented: $annonce) {
            NavigationStack { FormulaireAnnonce() }.feuilleEnVerre()
        }
    }

    /// Toucher un widget ouvre son écran détaillé.
    private func lien<Destination: View, Contenu: View>(_ destination: Destination,
                                                        @ViewBuilder contenu: () -> Contenu) -> some View {
        NavigationLink { destination } label: { contenu() }
            .buttonStyle(.plain)
    }

    private func ligne<Destination: View>(_ libelle: String, _ icone: String, _ couleur: Color,
                                          @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            LigneReglage(icone: icone, couleur: couleur, libelle: libelle)
        }
        .buttonStyle(.plain)
    }

    private var enPause: Bool {
        foyer.connecte ? foyer.sportDuServeur?.pause != nil : foyer.essais.pause
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
        .feuilleEnVerre()
        // Pas de fond à nous : la feuille d'iOS est en Liquid Glass, l'écran reste visible dessous.
    }
}
