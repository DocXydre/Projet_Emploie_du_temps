import SwiftUI

/// Le démarrage de HAL, en plein écran (7.1 à 7.17). « Plus tard » le ferme :
/// l'appli reste utilisable sans plan, et Sport propose de le reprendre (DEM-1).
struct EcranDemarrage: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.dismiss) private var fermer
    @State private var modele = ModeleDemarrage()

    static func nomDuBloc(_ bloc: String) -> String {
        switch bloc {
        case "profil": "ton profil"
        case "limitations": "les douleurs et limitations"
        case "lieux": "tes lieux de sport"
        case "objectif": "ton objectif"
        default: bloc
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !modele.charge {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    contenu
                        .id(modele.page)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: modele.page)
            .background { Fond() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if modele.peutRevenir {
                        Button("Retour", systemImage: "chevron.left") { modele.revenir() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(modele.page == .fini ? "Fermer" : "Plus tard") { terminer() }
                }
            }
        }
        .environment(modele)
        .task {
            modele.client = foyer.client
            await modele.charger()
        }
    }

    private func terminer() {
        Task {
            await modele.garderLeBrouillon()
            await foyer.charger()
        }
        fermer()
    }

    @ViewBuilder private var contenu: some View {
        switch modele.page {
        case .bienvenue: Bienvenue()
        case .identite: Identite()
        case .niveaux: Niveaux()
        case .disponibilites: Disponibilites()
        case .alimentation: Alimentation()
        case .limitationQuestion: QuestionLimitation(autre: false)
        case .limitationDetail: DetailLimitation()
        case .limitationExercices: ExercicesAEviter()
        case .limitationAutre: QuestionLimitation(autre: true)
        case .lieux: Lieux()
        case .objectif: ChoixObjectif()
        case .course: Course()
        case .recap: Recapitulatif()
        case .construction: Construction()
        case .plan: PlanPret()
        case .fini: CestParti { terminer() }
        }
    }
}

// MARK: - La charpente d'un écran

/// Un écran du démarrage : l'avancée, le titre, le contenu, un champ libre, et
/// le bouton pour continuer en bas.
private struct Page<Contenu: View, Entete: View>: View {
    let titre: String
    var texte: String? = nil
    var note: String? = nil
    var bouton: String? = "Continuer"
    var actif = true
    @ViewBuilder var contenu: Contenu
    /// Ce qui passe au-dessus du titre : la grande orbe de la bienvenue (7.1).
    @ViewBuilder var entete: Entete
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                entete
                if let etape = modele.page.etape {
                    Avancee(etape: etape)
                    Text(modele.page.repere).texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                }
                HStack(alignment: .top, spacing: 12) {
                    if modele.page.etape != nil { Orbe(etat: .repos, taille: 34).padding(.top, 2) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                            .fixedSize(horizontal: false, vertical: true)
                        if let texte {
                            Text(texte).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                contenu
                if let note { ChampLibre(cle: note) }
                if let erreur = modele.erreur {
                    Label(erreur, systemImage: "exclamationmark.circle")
                        .texte(.corps).foregroundStyle(Categorie.alerte.couleur)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Espace.marge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if let bouton {
                Button { Task { await modele.suivant() } } label: {
                    HStack {
                        if modele.envoi { ProgressView() }
                        Text(bouton)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                .disabled(!actif || modele.envoi)
                .padding(.horizontal, Espace.marge)
                .padding(.bottom, 8)
            }
        }
    }
}

extension Page where Entete == EmptyView {
    init(titre: String, texte: String? = nil, note: String? = nil, bouton: String? = "Continuer",
         actif: Bool = true, @ViewBuilder contenu: () -> Contenu) {
        self.init(titre: titre, texte: texte, note: note, bouton: bouton, actif: actif,
                  contenu: contenu, entete: { EmptyView() })
    }
}

/// Les cinq étapes, et celle où l'on est.
private struct Avancee: View {
    let etape: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { rang in
                Capsule()
                    .fill(rang <= etape ? Categorie.ia.couleur : Palette.verreTeinteForte)
                    .frame(height: 5)
            }
        }
        .accessibilityLabel("Étape \(etape) sur 5")
    }
}

/// Une question : des réponses à toucher, une seule à la fois.
private struct ChoixUnique<Valeur: Hashable>: View {
    var titre: String? = nil
    let choix: [(Valeur, String)]
    /// Une ligne sous chaque réponse, si elle aide à choisir (7.3, 7.5, 7.6).
    var details: [Valeur: String] = [:]
    @Binding var selection: Valeur?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let titre { Text(titre.uppercased()).texte(.etiquette).foregroundStyle(Palette.texteSecondaire) }
            ForEach(choix.indices, id: \.self) { rang in
                let valeur = choix[rang].0
                let choisi = selection == valeur
                Button { selection = valeur } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choix[rang].1).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                            if let detail = details[valeur] {
                                Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            }
                        }
                        Spacer()
                        if choisi {
                            Image(systemName: "checkmark").font(.body.weight(.semibold))
                                .foregroundStyle(Categorie.sport.couleur)
                        }
                    }
                    .padding(.horizontal, Espace.interne)
                    .padding(.vertical, 10)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .carte(rayon: Rayon.controle)
                .overlay(RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous)
                    .strokeBorder(choisi ? Categorie.sport.couleur : .clear, lineWidth: 1.5))
                .accessibilityAddTraits(choisi ? .isSelected : [])
            }
        }
    }
}

/// Une question à réponses courtes : des pastilles côte à côte.
private struct ChoixEnPuces<Valeur: Hashable>: View {
    var titre: String? = nil
    let choix: [(Valeur, String)]
    @Binding var selection: Valeur?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let titre { Text(titre.uppercased()).texte(.etiquette).foregroundStyle(Palette.texteSecondaire) }
            Flux(espacement: 8) {
                ForEach(choix.indices, id: \.self) { rang in
                    PuceChoix(texte: choix[rang].1, choisie: selection == choix[rang].0) {
                        selection = choix[rang].0
                    }
                }
            }
        }
    }
}

/// Le champ libre de chaque écran : gardé, et lu par HAL (DEM-1).
private struct ChampLibre: View {
    let cle: String
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        let texte = Binding { modele.notes[cle] ?? "" } set: { modele.notes[cle] = $0 }
        VStack(alignment: .leading, spacing: 6) {
            Text("AUTRE CHOSE À DIRE À HAL ? (FACULTATIF)").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
            TextField("Écris ici…", text: texte, axis: .vertical)
                .lineLimit(1...4)
                .texte(.corps)
                .foregroundStyle(Palette.textePrincipal)
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
        }
    }
}

// MARK: - 7.1 Bienvenue

private struct Bienvenue: View {
    var body: some View {
        Page(titre: "Je suis HAL, ton coach", texte: "Avant de te proposer un plan, j'ai besoin de te connaître. Cinq étapes, environ quatre minutes. Tu pourras tout changer ensuite dans Réglages.", bouton: "Commencer") {
            VStack(spacing: 0) {
                ligne(1, "Profil", "âge, taille, niveaux, disponibilités", "person")
                Divider().overlay(Palette.verreBord)
                ligne(2, "Limitation", "une douleur ou une gêne qui dure", "exclamationmark.circle")
                Divider().overlay(Palette.verreBord)
                ligne(3, "Lieux", "où tu fais chaque sport", "mappin.and.ellipse")
                Divider().overlay(Palette.verreBord)
                ligne(4, "Objectif", "ce que tu veux atteindre", "scope")
                Divider().overlay(Palette.verreBord)
                ligne(5, "Plan", "HAL construit tes 4 semaines", "calendar")
            }
            .carte()
            Text("Rien de médical ici : HAL est un coach sportif. Pour une douleur qui inquiète, vois un médecin.")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
        } entete: {
            Orbe(etat: .repos, taille: 110)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private func ligne(_ rang: Int, _ titre: String, _ detail: String, _ icone: String) -> some View {
        HStack(spacing: 12) {
            Text("\(rang)").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                .frame(width: 28, height: 28).background(Palette.verreTeinteForte, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            Spacer()
            Image(systemName: icone).foregroundStyle(Palette.texteSecondaire)
        }
        .padding(.horizontal, Espace.interne)
        .padding(.vertical, 10)
    }
}

// MARK: - 7.2 à 7.5 Profil

private struct Identite: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "Parle-moi un peu de toi", texte: "Ça sert à doser l'effort et les charges. HAL ne s'active qu'à partir de 18 ans.",
             note: "identite", actif: modele.sexe != nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Date de naissance").texte(.corps).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    DatePicker("Date de naissance", selection: $modele.naissance, in: ...Date.now,
                               displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "fr_FR"))
                }
                ChoixEnPuces(titre: "Sexe", choix: LibellesHAL.sexes, selection: $modele.sexe)
                HStack {
                    Text("Taille").texte(.corps).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    Compteur(titre: "Taille", valeur: $modele.taille, pas: 1, bornes: 100...250, unite: "cm",
                             compact: true)
                        .frame(width: 160)
                }
            }
            .padding(Espace.interne)
            .carte()
        }
    }
}

private struct Niveaux: View {
    @Environment(ModeleDemarrage.self) private var modele

    private static let details = ["debutant": "moins de 6 mois",
                                  "intermediaire": "régulier depuis plus de 6 mois",
                                  "avance": "plusieurs années, programmes suivis"]

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "Ton niveau ?", texte: "Pour que les premières séances soient justes.", note: "niveaux",
             actif: modele.niveauMusculation != nil && modele.niveauCourse != nil) {
            ChoixUnique(titre: "Musculation", choix: LibellesHAL.niveaux, details: Self.details,
                        selection: $modele.niveauMusculation)
            ChoixEnPuces(titre: "Course à pied", choix: LibellesHAL.niveaux, selection: $modele.niveauCourse)
        }
    }
}

private struct Disponibilites: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        let moment = Binding<String?> { modele.moment } set: { modele.moment = $0 ?? "indifferent" }
        Page(titre: "Quand tu peux t'entraîner ?", texte: "HAL lit déjà ton emploi du temps : il place les séances dans tes trous.", note: "disponibilites") {
            VStack(alignment: .leading, spacing: 14) {
                ChoixEnPuces(titre: "Moment préféré", choix: LibellesHAL.moments, selection: moment)
                VStack(alignment: .leading, spacing: 8) {
                    Text("JOURS SANS SPORT").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { jour in
                            let pris = modele.joursSansSport.contains(jour)
                            Button {
                                if pris { modele.joursSansSport.remove(jour) } else { modele.joursSansSport.insert(jour) }
                            } label: {
                                Text(String(LibellesHAL.jours[jour - 1].prefix(1))).texte(.corpsFort)
                                    .foregroundStyle(Palette.textePrincipal)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(pris ? Categorie.ia.voile : Palette.verreTeinte, in: Circle())
                                    .overlay(Circle().strokeBorder(pris ? Categorie.ia.couleur : Palette.verreBord,
                                                                   lineWidth: pris ? 1 : 0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Pas de sport le \(LibellesHAL.jours[jour - 1])")
                            .accessibilityAddTraits(pris ? .isSelected : [])
                        }
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Au plus par semaine").texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Button(modele.maximum == nil ? "HAL décide · fixer un maximum" : "Laisser HAL décider") {
                            modele.maximum = modele.maximum == nil ? 4 : nil
                        }
                        .texte(.legende)
                        .foregroundStyle(Categorie.ia.couleur)
                    }
                    Spacer()
                    if let maximum = modele.maximum {
                        Compteur(titre: "Séances", valeur: Binding { Double(maximum) } set: { modele.maximum = Int($0) },
                                 bornes: 1...7, unite: "séances", compact: true)
                            .frame(width: 150)
                    }
                }
            }
            .padding(Espace.interne)
            .carte()
        }
    }
}

private struct Alimentation: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "On parle alimentation ?", texte: "Seulement des conseils simples autour des séances. Jamais de régime.",
             note: "alimentation", actif: modele.complements != nil) {
            ChoixUnique(choix: [(true, "Oui, ça m'intéresse"), (false, "Non merci")],
                        details: [true: "repas avant et après l'effort, compléments", false: "HAL n'en parlera pas"],
                        selection: $modele.complements)
            VStack(alignment: .leading, spacing: 6) {
                Text("UN RÉGIME À RESPECTER").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                TextField("Végétarien, sans porc… ou rien", text: $modele.regime)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .padding(Espace.interne)
                    .carte(rayon: Rayon.controle)
            }
        }
    }
}

// MARK: - 7.6 à 7.8 Limitation

private struct QuestionLimitation: View {
    let autre: Bool
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        Page(titre: autre ? "Une autre ?" : "Une douleur ou une gêne qui dure ?",
             texte: autre ? nil : "Une blessure ancienne, une articulation fragile, un geste que tu ne peux pas faire. HAL en tient compte dans chaque séance. La question n'est posée qu'une fois.",
             bouton: nil) {
            if let deja = modele.etat?.limitations, !deja.isEmpty {
                Text("Déjà notées : " + deja.map(\.libelle).joined(separator: ", "))
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            }
            VStack(spacing: 8) {
                reponse("Oui", "je te dis où") { await modele.repondreLimitation(true) }
                reponse(autre ? "Non, c'est tout" : "Non, rien", "tu pourras en ajouter plus tard, dans Réglages") {
                    await modele.repondreLimitation(false)
                }
            }
            .disabled(modele.envoi)
        }
    }
}

extension QuestionLimitation {
    /// 7.6 : une réponse est une carte, et la toucher suffit.
    fileprivate func reponse(_ titre: String, _ detail: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Palette.texteTertiaire)
            }
            .padding(.horizontal, Espace.interne)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .carte(rayon: Rayon.controle)
    }
}

private struct DetailLimitation: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "Où ça ?", note: nil,
             actif: modele.zone != nil && modele.cote != nil && modele.description.count >= 5) {
            VStack(alignment: .leading, spacing: 14) {
                ChoixEnPuces(titre: "Zone", choix: LibellesHAL.zones,
                             selection: Binding { modele.zone } set: { modele.zone = $0 })
                ChoixEnPuces(titre: "Côté", choix: LibellesHAL.cotes,
                             selection: Binding { modele.cote } set: { modele.cote = $0 })
            }
            .padding(Espace.interne)
            .carte()
            VStack(alignment: .leading, spacing: 6) {
                Text("DÉCRIS-LA").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                TextField("Ce qui fait mal, quand, et le geste que tu ne peux pas faire", text: $modele.description,
                          axis: .vertical)
                    .lineLimit(3...6)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .padding(Espace.interne)
                    .carte(rayon: Rayon.controle)
            }
        }
    }
}

private struct ExercicesAEviter: View {
    @Environment(ModeleDemarrage.self) private var modele
    @State private var recherche = ""

    var body: some View {
        Page(titre: "Des exercices à éviter ?",
             texte: "Touche ceux qui te font mal. HAL ne les proposera plus. Aucun : continue.",
             bouton: modele.interdits.isEmpty ? "Passer" : "Continuer") {
            TextField("Chercher un exercice", text: $recherche)
                .texte(.corps).foregroundStyle(Palette.textePrincipal)
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
            if modele.catalogue.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            VStack(spacing: 0) {
                ForEach(filtres) { exercice in
                    let pris = modele.interdits.contains(exercice.code)
                    Button {
                        if pris { modele.interdits.remove(exercice.code) } else { modele.interdits.insert(exercice.code) }
                    } label: {
                        HStack {
                            Text(exercice.libelle).texte(.corps).foregroundStyle(Palette.textePrincipal)
                            Spacer()
                            Image(systemName: pris ? "nosign" : "circle")
                                .foregroundStyle(pris ? Categorie.alerte.couleur : Palette.texteTertiaire)
                        }
                        .padding(.horizontal, Espace.interne)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .carte(rayon: Rayon.controle)
        }
        .task { await modele.chargerLeCatalogue() }
    }

    private var filtres: [ExerciceCatalogue] {
        let mot = recherche.trimmingCharacters(in: .whitespaces).lowercased()
        let tous = modele.catalogue
        let choisis = tous.filter { modele.interdits.contains($0.code) }
        let autres = tous.filter { !modele.interdits.contains($0.code) &&
            (mot.isEmpty || $0.libelle.lowercased().contains(mot)) }
        return choisis + Array(autres.prefix(mot.isEmpty ? 25 : 60))
    }
}

// MARK: - 7.9 Lieux

private struct Lieux: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        Page(titre: "Où tu fais chaque sport ?",
             texte: "Touche tes lieux dans ton ordre de préférence. Une discipline que tu ne fais pas reste vide.",
             note: "lieux") {
            ForEach(LibellesHAL.disciplines, id: \.0) { discipline in
                let rangs = modele.lieux[discipline.0] ?? []
                VStack(alignment: .leading, spacing: 10) {
                    Label(discipline.1.uppercased(), systemImage: icone(discipline.0))
                        .texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                    Flux(espacement: 8) {
                        ForEach(modele.etat?.lieuxPossibles ?? []) { lieu in
                            let rang = rangs.firstIndex(of: lieu.idLieu)
                            PuceChoix(texte: rang.map { "\($0 + 1) · \(lieu.libelle)" } ?? lieu.libelle,
                                      choisie: rang != nil) {
                                modele.basculer(lieu.idLieu, pour: discipline.0)
                            }
                        }
                    }
                }
                .padding(Espace.interne)
                .frame(maxWidth: .infinity, alignment: .leading)
                .carte()
            }
        }
    }

    private func icone(_ discipline: String) -> String {
        switch discipline {
        case "musculation": "dumbbell"
        case "course": "figure.run"
        default: "heart"
        }
    }
}

// MARK: - 7.10 à 7.12 Objectif

private struct ChoixObjectif: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "Ton objectif principal ?",
             texte: "C'est lui qui commande le plan. Tu pourras en ajouter d'autres à côté, dans Objectifs.",
             note: "objectif", actif: modele.objectif != nil || modele.principal != nil) {
            if let principal = modele.principal, modele.objectif == nil {
                AvisDeHAL(texte: "Tu as déjà un objectif : \(principal.libelle). Continue pour le garder, ou choisis-en un autre.")
            }
            VStack(spacing: 8) {
                ForEach(LibellesHAL.objectifs, id: \.0) { choix in
                    let choisi = modele.objectif == choix.0
                    Button { modele.objectif = choix.0 } label: {
                        HStack(spacing: 12) {
                            Image(systemName: choix.2).font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Palette.texteSurAccent)
                                .frame(width: 36, height: 36)
                                .background(couleur(choix.0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choix.1).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                Text(detail(choix.0)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            }
                            Spacer()
                            if choisi {
                                Image(systemName: "checkmark").font(.body.weight(.semibold))
                                    .foregroundStyle(Categorie.sport.couleur)
                            }
                        }
                        .padding(.horizontal, Espace.interne)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .carte(rayon: Rayon.controle)
                    .overlay(RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous)
                        .strokeBorder(choisi ? Categorie.sport.couleur : .clear, lineWidth: 1.5))
                    .accessibilityAddTraits(choisi ? .isSelected : [])
                }
            }
        }
    }
}

extension ChoixObjectif {
    fileprivate func detail(_ objectif: String) -> String {
        switch objectif {
        case "force": "soulever plus lourd"
        case "physique": "prendre du volume"
        case "endurance": "tenir plus longtemps, être en forme"
        default: "une date et une distance"
        }
    }

    fileprivate func couleur(_ objectif: String) -> Color {
        switch objectif {
        case "force": Categorie.menage.couleur
        case "physique": Categorie.travail.couleur
        case "endurance": Categorie.ia.couleur
        default: Categorie.sport.couleur
        }
    }
}

private struct Course: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        let pret = (modele.distanceChoisie ?? 0) > 0
            && (modele.justeFinir || LibellesHAL.minutes(modele.tempsVise) != nil)
        Page(titre: "Quelle course ?", texte: "Le temps visé peut être ambitieux : HAL te dira ce qu'il en pense.",
             note: "course", actif: pret) {
            VStack(alignment: .leading, spacing: 14) {
                Text("DISTANCE").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                Flux(espacement: 8) {
                    ForEach(LibellesHAL.distances, id: \.0) { choix in
                        PuceChoix(texte: choix.1, choisie: modele.distance == choix.0) {
                            modele.distance = choix.0
                            modele.autreDistance = ""
                        }
                    }
                }
                TextField("Ou une autre, en km", text: $modele.autreDistance)
                    .keyboardType(.decimalPad)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .verreControle(Capsule(), interactif: false)
                    .onChange(of: modele.autreDistance) { _, texte in if !texte.isEmpty { modele.distance = nil } }
                Divider().overlay(Palette.verreBord)
                HStack {
                    Text("Date").texte(.corps).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    DatePicker("Date de la course", selection: $modele.dateCourse, in: Date.now..., displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "fr_FR"))
                }
                HStack {
                    Text("Temps visé").texte(.corps).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    TextField("1 h 55", text: $modele.tempsVise)
                        .multilineTextAlignment(.trailing)
                        .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                        .frame(width: 110)
                        .disabled(modele.justeFinir)
                        .opacity(modele.justeFinir ? 0.4 : 1)
                }
                Toggle("Juste la finir", isOn: $modele.justeFinir)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .tint(Categorie.sport.couleur)
            }
            .padding(Espace.interne)
            .carte()
        }
    }
}

// MARK: - 7.13 Récapitulatif

private struct Recapitulatif: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        let fini = modele.etat?.manque == nil && modele.etat?.plan == true && modele.objectif == nil
        Page(titre: fini ? "Ton démarrage" : "Je résume, tu corriges si besoin",
             texte: fini ? "Tout est rempli et ton plan tourne. Chaque ligne se corrige." : "Touche une ligne pour la corriger.",
             bouton: fini ? nil : "Construire mon plan",
             actif: modele.objectif != nil || modele.principal != nil) {
            groupe("Profil") {
                ligne("Toi", profil, .identite)
                ligne("Niveaux", niveaux, .niveaux)
                ligne("Quand", disponibilites, .disponibilites)
                ligne("Repas", alimentation, .alimentation)
            }
            groupe("Limitation") { ligne("Gênes", limitations, .limitationQuestion) }
            groupe("Lieux") { ligne("Où", lieux, .lieux) }
            groupe("Objectif") { ligne("Principal", modele.objectifEnClair, .objectif) }
            if !fini {
                Text("HAL construit tes quatre semaines : ça prend quelques minutes.")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire)
            }
        }
    }

    /// 7.13 : un bloc du démarrage, en carte.
    private func groupe<Lignes: View>(_ titre: String, @ViewBuilder lignes: () -> Lignes) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titre.uppercased()).texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                .padding(.horizontal, Espace.interne)
                .padding(.top, 12)
            lignes()
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte()
    }

    private func ligne(_ titre: String, _ valeur: String, _ page: PageDemarrage) -> some View {
        Button { modele.aller(page) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .frame(width: 70, alignment: .leading)
                Text(valeur).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "pencil").font(.footnote).foregroundStyle(Palette.texteSecondaire)
            }
            .padding(.horizontal, Espace.interne)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(titre) : \(valeur). Corriger")
    }

    private var profil: String {
        let age = Calendar.current.dateComponents([.year], from: modele.naissance, to: .now).year ?? 0
        return [LibellesHAL.nom(modele.sexe, dans: LibellesHAL.sexes), "\(age) ans", "\(Int(modele.taille)) cm"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var niveaux: String {
        "Musculation \(LibellesHAL.nom(modele.niveauMusculation, dans: LibellesHAL.niveaux).lowercased()), course \(LibellesHAL.nom(modele.niveauCourse, dans: LibellesHAL.niveaux).lowercased())"
    }

    private var disponibilites: String {
        var morceaux = [LibellesHAL.nom(modele.moment, dans: LibellesHAL.moments)]
        if !modele.joursSansSport.isEmpty {
            morceaux.append("jamais le " + modele.joursSansSport.sorted().map { LibellesHAL.jours[$0 - 1].lowercased() }
                .joined(separator: ", "))
        }
        morceaux.append(modele.maximum.map { "\($0) séances au plus" } ?? "HAL décide du nombre")
        return morceaux.joined(separator: " · ")
    }

    private var alimentation: String {
        [modele.complements == true ? "Compléments : oui" : "Compléments : non",
         modele.regime.isEmpty ? nil : modele.regime].compactMap { $0 }.joined(separator: " · ")
    }

    private var limitations: String {
        let deja = modele.etat?.limitations.map(\.libelle) ?? []
        return deja.isEmpty ? "Aucune" : deja.joined(separator: ", ")
    }

    private var lieux: String {
        let noms = Dictionary(uniqueKeysWithValues: (modele.etat?.lieuxPossibles ?? []).map { ($0.idLieu, $0.libelle) })
        let lignes = LibellesHAL.disciplines.compactMap { discipline -> String? in
            guard let choisis = modele.lieux[discipline.0], !choisis.isEmpty else { return nil }
            return "\(discipline.1) : " + choisis.compactMap { noms[$0] }.joined(separator: ", ")
        }
        return lignes.isEmpty ? "Aucun" : lignes.joined(separator: "\n")
    }
}

// MARK: - 7.14 à 7.17 Le plan

private struct Construction: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        Page(titre: "Je prépare tes 4 semaines…", bouton: modele.attendLePlan ? nil : "Continuer") {
            VStack(alignment: .leading, spacing: 8) {
                etape("Ton emploi du temps lu", faite: true)
                etape("Tes lieux et trajets", faite: true)
                etape("Avis sur ton objectif", faite: modele.avis != nil)
                etape("Semaine de calibrage", faite: modele.plan != nil)
            }
            .frame(maxWidth: .infinity)
            if let avis = modele.avis {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SON AVIS SUR TON OBJECTIF").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                    AvisDeHAL(texte: avis)
                }
                .padding(Espace.interne)
                .carte()
            }
            if modele.attendLePlan {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Tu peux fermer : le plan arrive aussi en message.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Espace.interne)
                .carte()
            } else if modele.plan == nil {
                Text("Le plan n'est pas encore là. Il arrivera en message dans HAL.")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            }
        } entete: {
            Orbe(etat: modele.attendLePlan ? .active : .repos, taille: 110)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

extension Construction {
    fileprivate func etape(_ texte: String, faite: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: faite ? "checkmark" : "clock")
                .foregroundStyle(faite ? Categorie.sport.couleur : Palette.texteSecondaire)
                .frame(width: 20)
            Text(texte).texte(.corps).foregroundStyle(faite ? Palette.textePrincipal : Palette.texteSecondaire)
        }
    }
}

private struct PlanPret: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        Page(titre: "Ton plan sur quatre semaines", bouton: "C'est noté") {
            if let feuille = modele.plan?.feuilleDeRoute, !feuille.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LA FEUILLE DE ROUTE").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                    Text(feuille).texte(.corps).foregroundStyle(Palette.textePrincipal)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Espace.interne)
                .carte()
            }
            VStack(spacing: 0) {
                ForEach(modele.plan?.plan?.semaines ?? [], id: \.self) { semaine in
                    NavigationLink { EcranSemaine(lundi: semaine.lundi) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Semaine du \(semaine.lundi.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR"))))")
                                    .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                Text(TexteHAL.role(semaine.role).capitalized + (semaine.intention.map { " · \($0)" } ?? ""))
                                    .texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(2)
                            }
                            Spacer()
                            if semaine.validee != nil {
                                Image(systemName: "checkmark.seal").foregroundStyle(Categorie.sport.couleur)
                            }
                            Image(systemName: "chevron.right").foregroundStyle(Palette.texteTertiaire)
                        }
                        .padding(.horizontal, Espace.interne)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .carte()
            AvisDeHAL(texte: "La première semaine est la semaine de calibrage : ouvre-la et valide-la en une fois. Les autres sont des esquisses que HAL détaille au fil des semaines.",
                      secondaire: true)
        }
    }
}

private struct CestParti: View {
    let fermer: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Orbe(etat: .repos, taille: 96)
            Text("C'est parti").texte(.grandTitre).foregroundStyle(Palette.textePrincipal)
            Text("HAL te fait son récap ce soir. D'ici là, ta semaine est dans Sport.")
                .texte(.corps).foregroundStyle(Palette.texteSecondaire).multilineTextAlignment(.center)
            Spacer()
            Button("Retour à Aujourd'hui", action: fermer)
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
        }
        .padding(Espace.marge)
    }
}
