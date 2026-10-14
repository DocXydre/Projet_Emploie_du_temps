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
private struct Page<Contenu: View>: View {
    let titre: String
    var texte: String? = nil
    var note: String? = nil
    var bouton: String? = "Continuer"
    var actif = true
    @ViewBuilder var contenu: Contenu
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                if let etape = modele.page.etape { Avancee(etape: etape) }
                Text(titre).texte(.grandTitre).foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
                if let texte {
                    Text(texte).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
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
    @Binding var selection: Valeur?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let titre { Text(titre.uppercased()).texte(.etiquette).foregroundStyle(Palette.texteSecondaire) }
            ForEach(choix.indices, id: \.self) { rang in
                let valeur = choix[rang].0
                Button { selection = valeur } label: {
                    HStack {
                        Text(choix[rang].1).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        Image(systemName: selection == valeur ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection == valeur ? Categorie.ia.couleur : Palette.texteTertiaire)
                    }
                    .padding(.horizontal, Espace.interne)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .carte(rayon: Rayon.controle)
                .accessibilityAddTraits(selection == valeur ? .isSelected : [])
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
            Text("AUTRE CHOSE À DIRE À HAL ?").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
            TextField("Facultatif", text: texte, axis: .vertical)
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
        Page(titre: "Faisons connaissance", texte: "HAL a besoin de quelques réponses pour te proposer quatre semaines d'entraînement autour de ton emploi du temps. Tout se corrige ensuite.", bouton: "Commencer") {
            VStack(alignment: .leading, spacing: 14) {
                ligne(1, "Ton profil", "Âge, niveau, disponibilités, alimentation")
                ligne(2, "Douleurs et limitations", "S'il y a un geste à éviter")
                ligne(3, "Tes lieux de sport", "Salle, dehors, à la maison")
                ligne(4, "Ton objectif", "Force, muscle, endurance, ou une course")
                ligne(5, "Ton plan", "L'avis de HAL et la première semaine à valider")
            }
            .padding(Espace.interne)
            .carte()
            Text("Rien de médical ici : HAL est un coach sportif. Pour une douleur qui inquiète, vois un médecin.")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
        }
    }

    private func ligne(_ rang: Int, _ titre: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(rang)").texte(.corpsFort).foregroundStyle(Palette.texteSurAccent)
                .frame(width: 28, height: 28).background(Categorie.ia.couleur, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
        }
    }
}

// MARK: - 7.2 à 7.5 Profil

private struct Identite: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "Toi", texte: "HAL ne s'active qu'à partir de 18 ans.", note: "identite", actif: modele.sexe != nil) {
            VStack(alignment: .leading, spacing: 8) {
                Text("DATE DE NAISSANCE").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                DatePicker("Date de naissance", selection: $modele.naissance, in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "fr_FR"))
                    .frame(maxWidth: .infinity)
                    .carte(rayon: Rayon.controle)
            }
            ChoixUnique(titre: "Sexe", choix: LibellesHAL.sexes, selection: $modele.sexe)
            Compteur(titre: "Taille", valeur: $modele.taille, pas: 1, bornes: 100...250, unite: "cm")
        }
    }
}

private struct Niveaux: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "Ton niveau", note: "niveaux",
             actif: modele.niveauMusculation != nil && modele.niveauCourse != nil) {
            ChoixUnique(titre: "En musculation", choix: LibellesHAL.niveaux, selection: $modele.niveauMusculation)
            ChoixUnique(titre: "En course à pied", choix: LibellesHAL.niveaux, selection: $modele.niveauCourse)
        }
    }
}

private struct Disponibilites: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        let moment = Binding<String?> { modele.moment } set: { modele.moment = $0 ?? "indifferent" }
        Page(titre: "Tes disponibilités", texte: "HAL place les séances autour de tes cours et de ton travail.", note: "disponibilites") {
            ChoixUnique(titre: "Quand préfères-tu t'entraîner ?", choix: LibellesHAL.moments, selection: moment)
            VStack(alignment: .leading, spacing: 8) {
                Text("LES JOURS SANS SPORT, JAMAIS").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { jour in
                        let pris = modele.joursSansSport.contains(jour)
                        Button {
                            if pris { modele.joursSansSport.remove(jour) } else { modele.joursSansSport.insert(jour) }
                        } label: {
                            Text(LibellesHAL.jours[jour - 1]).texte(.corpsFort)
                                .foregroundStyle(pris ? Palette.texteSurAccent : Palette.textePrincipal)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(pris ? Categorie.ia.couleur : Palette.verreTeinte,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(pris ? .isSelected : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("AU PLUS, PAR SEMAINE").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                Picker("Séances par semaine", selection: $modele.maximum) {
                    Text("HAL décide").tag(Int?.none)
                    ForEach(2...7, id: \.self) { n in Text("\(n) séances").tag(Int?.some(n)) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, Espace.interne)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .carte(rayon: Rayon.controle)
            }
        }
    }
}

private struct Alimentation: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "Ton alimentation", note: "alimentation", actif: modele.complements != nil) {
            ChoixUnique(titre: "HAL peut-il te parler de compléments (protéines, créatine) ?",
                        choix: [(true, "Oui"), (false, "Non")], selection: $modele.complements)
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
        Page(titre: autre ? "Une autre ?" : "Une douleur qui dure ?",
             texte: autre ? nil : "Une articulation fragile, une ancienne blessure, un geste que tu ne peux pas faire. HAL en tiendra compte dans chaque séance. La question n'est posée qu'une fois.",
             bouton: nil) {
            if let deja = modele.etat?.limitations, !deja.isEmpty {
                Text("Déjà notées : " + deja.map(\.libelle).joined(separator: ", "))
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            }
            HStack(spacing: Espace.gouttiere) {
                Button(autre ? "Non, c'est tout" : "Non") { Task { await modele.repondreLimitation(false) } }
                    .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
                Button("Oui") { Task { await modele.repondreLimitation(true) } }
                    .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
            }
            .disabled(modele.envoi)
        }
    }
}

private struct DetailLimitation: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "Où, et quoi ?", note: nil,
             actif: modele.zone != nil && modele.cote != nil && modele.description.count >= 5) {
            VStack(alignment: .leading, spacing: 8) {
                Text("OÙ").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(LibellesHAL.zones, id: \.0) { zone in
                        puce(zone.1, choisie: modele.zone == zone.0) { modele.zone = zone.0 }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("DE QUEL CÔTÉ").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                HStack(spacing: 8) {
                    ForEach(LibellesHAL.cotes, id: \.0) { cote in
                        puce(cote.1, choisie: modele.cote == cote.0) { modele.cote = cote.0 }
                    }
                }
            }
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

/// Une petite réponse à toucher, dans une grille.
private func puce(_ libelle: String, choisie: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(libelle).texte(.corpsFort)
            .foregroundStyle(choisie ? Palette.texteSurAccent : Palette.textePrincipal)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(choisie ? Categorie.ia.couleur : Palette.verreTeinte,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(choisie ? .isSelected : [])
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
        Page(titre: "Tes lieux de sport",
             texte: "Pour chaque discipline, touche tes lieux dans ton ordre de préférence. Une discipline que tu ne fais pas reste vide.",
             note: "lieux") {
            ForEach(LibellesHAL.disciplines, id: \.0) { discipline in
                VStack(alignment: .leading, spacing: 8) {
                    Text(discipline.1.uppercased()).texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                    VStack(spacing: 0) {
                        ForEach(modele.etat?.lieuxPossibles ?? []) { lieu in
                            let rang = modele.lieux[discipline.0]?.firstIndex(of: lieu.idLieu)
                            Button { modele.basculer(lieu.idLieu, pour: discipline.0) } label: {
                                HStack {
                                    Text(lieu.libelle).texte(.corps).foregroundStyle(Palette.textePrincipal)
                                    Spacer()
                                    if let rang {
                                        Text("\(rang + 1)").texte(.corpsFort).foregroundStyle(Palette.texteSurAccent)
                                            .frame(width: 26, height: 26).background(Categorie.ia.couleur, in: Circle())
                                    } else {
                                        Image(systemName: "circle").foregroundStyle(Palette.texteTertiaire)
                                    }
                                }
                                .padding(.horizontal, Espace.interne)
                                .frame(minHeight: 46)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .carte(rayon: Rayon.controle)
                }
            }
        }
    }
}

// MARK: - 7.10 à 7.12 Objectif

private struct ChoixObjectif: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        Page(titre: "Ton objectif principal",
             texte: "Tu pourras en ajouter d'autres ensuite, dans Objectifs.",
             note: "objectif", actif: modele.objectif != nil || modele.principal != nil) {
            if let principal = modele.principal, modele.objectif == nil {
                AvisDeHAL(texte: "Tu as déjà un objectif : \(principal.libelle). Continue pour le garder, ou choisis-en un autre.")
            }
            VStack(spacing: 8) {
                ForEach(LibellesHAL.objectifs, id: \.0) { choix in
                    Button { modele.objectif = choix.0 } label: {
                        HStack(spacing: 12) {
                            Image(systemName: choix.2).font(.system(size: 20))
                                .foregroundStyle(Categorie.sport.couleur).frame(width: 32)
                            Text(choix.1).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                            Spacer()
                            Image(systemName: modele.objectif == choix.0 ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(modele.objectif == choix.0 ? Categorie.ia.couleur : Palette.texteTertiaire)
                        }
                        .padding(.horizontal, Espace.interne)
                        .frame(minHeight: 60)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .carte(rayon: Rayon.controle)
                }
            }
        }
    }
}

private struct Course: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        @Bindable var modele = modele
        let pret = (modele.distanceChoisie ?? 0) > 0
            && (modele.justeFinir || LibellesHAL.minutes(modele.tempsVise) != nil)
        Page(titre: "Ta course", texte: "Le temps visé peut être ambitieux : HAL te dira ce qu'il en pense.",
             note: "course", actif: pret) {
            VStack(alignment: .leading, spacing: 8) {
                Text("LA DISTANCE").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                HStack(spacing: 8) {
                    ForEach(LibellesHAL.distances, id: \.0) { choix in
                        puce(choix.1, choisie: modele.distance == choix.0) {
                            modele.distance = choix.0
                            modele.autreDistance = ""
                        }
                    }
                }
                TextField("Ou une autre, en km", text: $modele.autreDistance)
                    .keyboardType(.decimalPad)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .padding(Espace.interne)
                    .carte(rayon: Rayon.controle)
                    .onChange(of: modele.autreDistance) { _, texte in if !texte.isEmpty { modele.distance = nil } }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("LE TEMPS VISÉ").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                TextField("50 min, ou 1h45", text: $modele.tempsVise)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .padding(Espace.interne)
                    .carte(rayon: Rayon.controle)
                    .disabled(modele.justeFinir)
                    .opacity(modele.justeFinir ? 0.5 : 1)
                Toggle("Juste la finir", isOn: $modele.justeFinir)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .padding(.horizontal, Espace.interne)
                    .frame(minHeight: 48)
                    .carte(rayon: Rayon.controle)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("LA DATE").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                DatePicker("Date de la course", selection: $modele.dateCourse, in: Date.now..., displayedComponents: .date)
                    .environment(\.locale, Locale(identifier: "fr_FR"))
                    .padding(.horizontal, Espace.interne)
                    .frame(minHeight: 48)
                    .carte(rayon: Rayon.controle)
            }
        }
    }
}

// MARK: - 7.13 Récapitulatif

private struct Recapitulatif: View {
    @Environment(ModeleDemarrage.self) private var modele

    var body: some View {
        let fini = modele.etat?.manque == nil && modele.etat?.plan == true && modele.objectif == nil
        Page(titre: fini ? "Ton démarrage" : "Tout est bon ?",
             texte: fini ? "Tout est rempli et ton plan tourne. Chaque ligne se corrige." : "Touche une ligne pour la corriger.",
             bouton: fini ? nil : "C'est bon, HAL peut construire mon plan",
             actif: modele.objectif != nil || modele.principal != nil) {
            VStack(spacing: 0) {
                ligne("Toi", profil, .identite)
                ligne("Niveaux", niveaux, .niveaux)
                ligne("Disponibilités", disponibilites, .disponibilites)
                ligne("Alimentation", alimentation, .alimentation)
                ligne("Limitations", limitations, .limitationQuestion)
                ligne("Lieux", lieux, .lieux)
                ligne("Objectif", modele.objectifEnClair, .objectif)
            }
            .carte()
            if !fini {
                Text("HAL donne d'abord son avis sur l'objectif, puis construit quatre semaines. Ça prend quelques minutes.")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire)
            }
        }
    }

    private func ligne(_ titre: String, _ valeur: String, _ page: PageDemarrage) -> some View {
        Button { modele.aller(page) } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titre.uppercased()).texte(.etiquette).foregroundStyle(Palette.texteTertiaire)
                    Text(valeur).texte(.corps).foregroundStyle(Palette.textePrincipal)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "pencil").foregroundStyle(Palette.texteSecondaire)
            }
            .padding(.horizontal, Espace.interne)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        Page(titre: "HAL construit ton plan", bouton: modele.attendLePlan ? nil : "Continuer") {
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
                    Text("Il place quatre semaines autour de ton emploi du temps. Tu peux fermer : le plan arrive aussi en message.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Espace.interne)
                .carte()
            } else if modele.plan == nil {
                Text("Le plan n'est pas encore là. Il arrivera en message dans HAL, et la semaine à valider apparaîtra dans Sport.")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            }
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
