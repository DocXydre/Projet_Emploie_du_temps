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
                              ? "Ajoute ce qui revient : la vaisselle, les lessives, la litière."
                              : "C'est l'administrateur du foyer qui ajoute les tâches.",
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
            // 4.1 : les tâches du jour des deux, l'équilibre, Sassy et le linge, ce qui arrive.
            // Ici les tuiles prennent la hauteur de leur contenu, comme la maquette :
            // pas de carré ni de format moyen imposé.
            TachesDuJourDesDeux()
            // 4.12 : toutes les tâches du foyer, rangées par type ; chacune s'ouvre (4.2).
            NavigationLink { EcranToutesLesTaches() } label: {
                LigneReglage(icone: "checklist", couleur: Categorie.menage.couleur,
                             libelle: "Toutes les tâches", accessoire: .chevron(nil))
                    .padding(.horizontal, Espace.interne)
                    .padding(.vertical, Espace.serre)
                    .carte(rayon: Rayon.controle)
            }
            .buttonStyle(.plain)
            Module.equilibre.widget(.moyen).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Espace.gouttiere) {
                Module.chat.widget(.petit)
                Module.linge.widget(.petit)
            }
            .fixedSize(horizontal: false, vertical: true)
            NavigationLink { EcranPlanning() } label: {
                Module.bientot.widget(.moyen).fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
        }
        .refreshable { await foyer.charger() }
        .sheet(isPresented: $ajoutRapide) { AjoutRapide().presentationDetents([.fraction(0.64), .large]) }
    }
}

/// 4.1 : toutes les tâches du jour des deux, avec l'heure ou le retard, et à
/// qui elles reviennent. Cocher celle de l'autre la crédite à qui l'a faite (EXE-14).
private struct TachesDuJourDesDeux: View {
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        let taches = foyer.tachesDuJour
        CoquilleWidget(titre: "Aujourd'hui", icone: "checklist", couleur: Categorie.menage.couleur,
                       droite: taches.isEmpty ? nil : "\(taches.filter(\.faite).count) sur \(taches.count)") {
            if taches.isEmpty {
                Text("Aucune tâche aujourd'hui.").texte(.corps).foregroundStyle(Palette.texteSecondaire)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(taches) { tache in
                        LigneTache(titre: tache.titre, faite: tache.faite,
                                   detail: detail(tache), detailEnAlerte: tache.enRetard && !tache.faite,
                                   avatar: foyer.membres.count > 1
                                       ? (tache.pourQui.nom, foyer.couleur(de: tache.pourQui)) : nil,
                                   type: tache.type.map { ($0.icone, tache.couleur) },
                                   annulableJusqua: foyer.departDeLEnvoi(tache)) {
                            cocher(tache)
                        }
                        .contextMenu {
                            if tache.reportable && !tache.faite {
                                Button("Repousser", systemImage: "arrow.uturn.forward") {
                                    withAnimation(.snappy) { foyer.reporter(tache, file: file) }
                                    annoncer("« \(tache.titre) » repoussée")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// « 21:00 », ou « 2 j de retard » en rouge.
    private func detail(_ tache: Tache) -> String? {
        if tache.enRetard && !tache.faite {
            let jours = tache.fin.map {
                Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: $0),
                                                to: Calendar.current.startOfDay(for: .now)).day ?? 0
            } ?? 0
            return jours > 0 ? "\(jours) j de retard" : "en retard"
        }
        guard !tache.journeeEntiere, let debut = tache.debut else { return nil }
        return EnFrancais.heure(debut)
    }

    private func cocher(_ tache: Tache) {
        // APP-10 : une tâche cochée se décoche d'un geste tant qu'elle n'est pas partie.
        guard !tache.faite else {
            var decochee = false
            withAnimation(.snappy) { decochee = foyer.decocher(tache) }
            if decochee { annoncer("« \(tache.titre) » décochée") }
            return
        }
        var annuler: (() -> Void)?
        withAnimation(.snappy) { annuler = foyer.cocher(tache, file: file) }
        if let annuler {
            annoncer("« \(tache.titre) » faite", annuler: { withAnimation(.snappy) { annuler() } })
        }
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
        case courseFaite = "Course faite"
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
            case .courseFaite: "sans rien pour l'enregistrer"
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
            case .courseFaite: "figure.run"
            case .mesure: "scalemass"
            case .allege: "moon"
            }
        }

        var categorie: Categorie {
            switch self {
            case .tache: .menage
            case .faite, .seanceLibre, .courseFaite: .sport
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
                case .absence: EcranAbsences()
                case .allege: FormulaireAllege()
                case .seanceLibre: FormulaireAnnonce()
                case .courseFaite: FormulaireCourseALaMain()
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
