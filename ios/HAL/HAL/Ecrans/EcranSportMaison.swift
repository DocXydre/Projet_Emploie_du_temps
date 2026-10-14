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
            BandeauServeur()
            if foyer.connecte && sante.disponible && !sante.accesDemande {
                // 8.7 : sans Santé, la forme, le sommeil et les séances de la montre restent vides.
                CarteVide(icone: "heart", categorie: .alerte, titre: "Santé n'est pas encore lue",
                          texte: "Ton sommeil, ta fréquence cardiaque et les séances de ta montre remplissent cet onglet, et aident HAL à doser tes séances.",
                          bouton: "Autoriser Santé") {
                    Task { await sante.demanderAcces() }
                }
            }
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
    @Environment(Aiguillage.self) private var aiguillage
    @State private var ajoutRapide = false

    var body: some View {
        PageDefilante {
            EnTeteOnglet(surTitre: ([foyer.moi.nom] + [foyer.autre?.nom].compactMap { $0 }).joined(separator: " et "),
                         titre: "Maison") {
                BoutonRond("plus", libelle: "Ajouter") { ajoutRapide = true }
            }
            .padding(.bottom, 4)
            BandeauServeur()
            // 8.8 : un foyer sans tâche, ou une personne seule, le disent avec de quoi agir.
            if foyer.sansTache {
                CarteVide(icone: "house", categorie: .menage, titre: "Aucune tâche dans le foyer",
                          texte: foyer.droits.ajouter
                              ? "Ajoute ce qui revient : la vaisselle, les lessives, la litière. Le moteur les place dans vos creux et les répartit."
                              : "C'est l'administrateur du foyer qui ajoute les tâches (FOY-6).",
                          bouton: foyer.droits.ajouter ? "Ajouter une tâche" : nil) {
                    aiguillage.feuille = .ajouterTache
                }
            }
            if foyer.connecte && foyer.autre == nil && foyer.moi.estAdministrateur {
                CarteVide(icone: "person.badge.plus", categorie: .ia, titre: "Tu es seul dans le foyer",
                          texte: "Invite la personne avec qui tu vis : vous partagerez les tâches, et la balance les répartira entre vous.",
                          bouton: "Inviter") {
                    aiguillage.feuille = .inviter
                }
            }
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
        .sheet(isPresented: $ajoutRapide) { AjoutRapide().presentationDetents([.fraction(0.64), .large]) }
    }
}

/// L'ajout rapide du « + » (APP-9). Tout se fait à la main, sans HAL.
struct AjoutRapide: View {
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @Environment(Foyer.self) private var foyer

    private enum Action: String, CaseIterable, Identifiable {
        case tache = "Tâche"
        case faite = "C'est fait"
        case creneau = "Créneau"
        case absence = "Absence"
        case seanceLibre = "Séance libre"
        case mesure = "Mesure"
        case allege = "Mode allégé"

        var id: String { rawValue }

        var sousTitre: String {
            switch self {
            case .tache: "une fois ou régulière"
            case .faite: "même celle de l'autre"
            case .creneau: "bloquer un moment"
            case .absence: "je pars, je rentre"
            case .seanceLibre: "à mon idée"
            case .mesure: "poids, tours"
            case .allege: "en faire moins"
            }
        }

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

    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Espace.gouttiere) {
                    HStack {
                        Text("Ajouter").texte(.titre).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        BoutonRond("xmark", libelle: "Fermer") { fermer() }
                    }
                    // 1.5 : toutes les actions d'un coup d'œil, deux par ligne,
                    // le mode allégé seul sur la dernière.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Espace.gouttiere),
                                        GridItem(.flexible(), spacing: Espace.gouttiere)],
                              spacing: Espace.gouttiere) {
                        ForEach(Action.allCases.filter { $0 != .allege }) { action in
                            tuile(action)
                        }
                    }
                    tuile(.allege)
                }
                .padding(Espace.marge)
            }
            .scrollBounceBehavior(.basedOnSize)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Action.self) { action in
                switch action {
                case .tache: FormulaireTache()
                case .faite: FormulaireFaite()
                case .creneau: FormulaireCreneau()
                case .absence: FormulaireAbsence()
                case .allege: FormulaireAllege()
                case .seanceLibre: FormulaireAnnonce()
                case .mesure: EcranMesures()
                }
            }
        }
        .environment(\.fermerFeuille, ActionFermer { fermer() })
        .feuilleEnVerre()
        // Pas de fond à nous : la feuille d'iOS est en Liquid Glass, l'écran reste visible dessous.
    }

    @ViewBuilder
    private func tuile(_ action: Action) -> some View {
        let contenu = HStack(spacing: 12) {
            Image(systemName: action.icone)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 36, height: 36)
                .background(action.categorie.couleur, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(action.rawValue).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Text(action.sousTitre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous)
            .strokeBorder(Palette.verreBord, lineWidth: 0.5))
        .contentShape(Rectangle())
        if foyer.connecte {
            NavigationLink(value: action) { contenu }.buttonStyle(.plain)
        } else {
            Button {
                fermer()
                annoncer("Connecte-toi à ton serveur pour « \(action.rawValue) »")
            } label: { contenu }
            .buttonStyle(.plain)
        }
    }
}
