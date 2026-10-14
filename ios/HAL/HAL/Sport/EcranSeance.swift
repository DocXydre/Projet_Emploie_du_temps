import SwiftUI

// La séance de musculation, de bout en bout (3.3 à 3.10). Tout marche sans
// réseau : la séance est chargée d'avance, les saisies attendent dans la file.

// MARK: - 3.3 Séance prévue

/// La séance prévue par HAL : ses exercices, « Lancer », « Déjà faite ».
struct EcranSeancePrevue: View {
    let detail: DetailSeance
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var pasFaite = false

    var body: some View {
        NavigationStack {
            FormulaireVerre {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                        Text(sousTitre).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    if let consigne = detail.seance.consigne, !consigne.isEmpty {
                        AvisDeHAL(texte: consigne)
                    }
                }
                Section("Exercices") {
                    if detail.prevu.isEmpty {
                        Text("HAL n'a pas encore détaillé cette séance : tu choisis tes exercices.")
                            .foregroundStyle(Palette.texteSecondaire)
                    }
                    ForEach(detail.prevu) { ligne in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ligne.libelle).foregroundStyle(Palette.textePrincipal)
                            Text(ligne.enClair).font(.footnote).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                }
                if let montre = detail.montre?.first {
                    Section("Enregistrée par la montre") { MontreEnClair(montre: montre) }
                    if let avis = detail.seance.avisLibre {
                        Section("HAL") { Text(avis).foregroundStyle(Palette.textePrincipal) }
                    }
                }
                Section {
                    if detail.seance.discipline == "musculation" {
                        Button {
                            seance.lancer(detail)
                            fermer()
                        } label: {
                            Label("Lancer la séance", systemImage: "play.fill").bold().frame(maxWidth: .infinity)
                        }
                    } else if !detail.close {
                        // MON-1 : une course ne se lance pas ici, elle part sur la montre.
                        Label("Envoyer à la montre : au lot 9", systemImage: "applewatch")
                            .foregroundStyle(Palette.texteSecondaire)
                    }
                    if !detail.close {
                        Button("Déjà faite, sans saisie") {
                            SeanceEnCours.dejaFaite(detail, file: file)
                            annoncer("Séance comptée faite")
                            fermer()
                        }
                        .frame(maxWidth: .infinity)
                        Button("Pas faite") { pasFaite = true }
                            .foregroundStyle(Palette.texteSecondaire)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Séance \(EcranSemaine.situation(detail.seance.situation))", systemImage: "checkmark.circle")
                            .foregroundStyle(Palette.texteSecondaire)
                    }
                } footer: {
                    Text("« Déjà faite » la compte sans charge : tu pourras donner ton bilan ensuite.")
                }
            }
            .navigationTitle("Séance du jour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { fermer() } }
            }
            .confirmationDialog("Cette séance n'a pas été faite ?", isPresented: $pasFaite,
                                titleVisibility: .visible) {
                Button("Pas faite", role: .destructive) {
                    file.ajouter(methode: "POST", chemin: "seances/\(detail.seance.idOccurrence)/pas-faite")
                    annoncer("Séance notée pas faite : HAL décide de la suite")
                    fermer()
                }
            } message: {
                Text("HAL en tient compte pour la suite de la semaine.")
            }
        }
        .feuilleEnVerre()
    }

    private var sousTitre: String {
        var morceaux: [String] = []
        if let debut = detail.seance.debut { morceaux.append(debut.formatted(date: .omitted, time: .shortened)) }
        if let duree = detail.seance.dureeMinutes { morceaux.append("\(duree) min") }
        if let lieu = detail.seance.lieu { morceaux.append(lieu) }
        morceaux.append("\(detail.prevu.count) exercice\(detail.prevu.count > 1 ? "s" : "")")
        return morceaux.joined(separator: " · ")
    }
}

/// 3.14 : une course faite, comme l'app Forme la montre.
private struct MontreEnClair: View {
    let montre: DetailSeance.Montre

    var body: some View {
        if let duree = montre.dureeSecondes {
            LabeledContent("Durée", value: "\(duree / 60) min \(String(format: "%02d", duree % 60)) s")
        }
        if let distance = montre.distanceM {
            LabeledContent("Distance", value: String(format: "%.2f km", Double(distance) / 1000))
        }
        if let allure = montre.allureSKm {
            LabeledContent("Allure", value: "\(allure / 60):\(String(format: "%02d", allure % 60)) /km")
        }
        if let fc = montre.fcMoyenne {
            LabeledContent("FC moyenne", value: "\(fc) bpm" + (montre.fcMax.map { " · max \($0)" } ?? ""))
        }
        if let denivele = montre.deniveleM { LabeledContent("Dénivelé", value: "\(denivele) m") }
        if let energie = montre.energieKcal { LabeledContent("Énergie", value: "\(energie) kcal") }
        if let cadence = montre.cadence { LabeledContent("Cadence", value: "\(cadence) pas/min") }
    }
}

// MARK: - 3.5 Séance en cours

/// Gros boutons, une main, les gants : la séance en cours (SAI-1, SAI-10).
struct EcranSeanceEnCours: View {
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @State private var charge: Double = 20
    @State private var reps: Double = 10
    @State private var duree: Double = 30
    @State private var distance: Double = 500
    @State private var bloque = false
    @State private var terminer = false
    @State private var choisir = false
    @State private var bilan = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Espace.gouttiere) {
                    entete
                    if let exercices = seance.seance?.exercices, !exercices.isEmpty {
                        rubanDesExercices(exercices)
                    }
                    if let fin = seance.finDuRepos, fin > .now {
                        Repos(fin: fin, duree: seance.dureeDuRepos) { seance.passerLeRepos() }
                    }
                    if let exercice = seance.exerciceCourant {
                        carteExercice(exercice)
                        saisie(exercice)
                    } else {
                        aucunExercice
                    }
                }
                .padding(Espace.marge)
            }
            .background { Fond() }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $bloque) {
                FeuilleBloque(repsVisees: Int(reps)) { faites in
                    seance.bloque(charge: charge, repsFaites: faites, repsVisees: Int(reps), file: file)
                    preRemplir()
                }
                .presentationDetents([.medium])
                .feuilleEnVerre()
            }
            .sheet(isPresented: $choisir) {
                ChoixExercice { exercice in seance.ajouter(exercice); preRemplir() }
                    .feuilleEnVerre()
            }
            .sheet(isPresented: $terminer) {
                FeuilleTerminer(prevue: seance.seance?.idOccurrence != nil) { choix in
                    switch choix {
                    case .bilan: bilan = true
                    case .pasFaite: seance.pasFaite(file: file)
                    }
                }
                .presentationDetents([.medium])
                .feuilleEnVerre()
            }
            .navigationDestination(isPresented: $bilan) { EcranBilan() }
        }
        .onAppear(perform: preRemplir)
        .onChange(of: seance.exerciceCourant?.id) { preRemplir() }
    }

    private var entete: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(seance.seance?.titre ?? "Séance").texte(.titre).foregroundStyle(Palette.textePrincipal)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("\(seance.minutesEcoulees) min · \(seance.seance?.series.count ?? 0) séries")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
            Spacer()
            BoutonRond("chevron.down", libelle: "Réduire") { seance.affichee = false }
            Button("Terminer") { terminer = true }.buttonStyle(.hal(.verreAccent))
        }
    }

    private func rubanDesExercices(_ exercices: [ExerciceDeSeance]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(exercices.indices, id: \.self) { rang in
                    let exercice = exercices[rang]
                    let faites = seance.series(de: exercice).count
                    Button { seance.aller(a: rang) } label: {
                        HStack(spacing: 6) {
                            Text(exercice.libelle).lineLimit(1)
                            if let prevues = exercice.series {
                                Text("\(min(faites, prevues))/\(prevues)").foregroundStyle(Palette.texteSecondaire)
                            } else if faites > 0 {
                                Text("\(faites)").foregroundStyle(Palette.texteSecondaire)
                            }
                        }
                        .texte(.corps)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .foregroundStyle(Palette.textePrincipal)
                    }
                    .buttonStyle(.plain)
                    .verreControle(Capsule(), teinte: rang == seance.seance?.courant ? Categorie.sport.voile : nil)
                }
                Button { choisir = true } label: {
                    Image(systemName: "plus").frame(width: 40, height: 40).foregroundStyle(Palette.textePrincipal)
                }
                .buttonStyle(.plain)
                .verreControle(Circle())
                .accessibilityLabel("Ajouter un exercice")
            }
        }
    }

    private func carteExercice(_ exercice: ExerciceDeSeance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(exercice.libelle).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                Spacer()
                if !exercice.alternatives.isEmpty {
                    Menu {
                        ForEach(exercice.alternatives, id: \.code) { alternative in
                            Button(alternative.libelle) { seance.remplacer(par: alternative); preRemplir() }
                        }
                    } label: {
                        Label("Changer", systemImage: "arrow.triangle.swap").texte(.legende)
                    }
                }
            }
            if let prevu = prevuEnClair(exercice) {
                Text(prevu).texte(.corps).foregroundStyle(Palette.texteSecondaire)
            }
            if let consigne = exercice.consigne, !consigne.isEmpty {
                AvisDeHAL(texte: consigne, style: .legende, secondaire: true)
            }
            let faites = seance.series(de: exercice)
            if !faites.isEmpty {
                ForEach(faites) { serie in
                    HStack {
                        Text("\(serie.numero)").texte(.corpsFort).foregroundStyle(Palette.texteTertiaire).frame(width: 22)
                        Text(serie.enClair).texte(.corps).foregroundStyle(Palette.textePrincipal)
                        if serie.bloquee {
                            Text("bloquée").texte(.legende).foregroundStyle(Categorie.alerte.couleur)
                        } else if serie.intermediaire {
                            Text("intermédiaire").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte()
    }

    @ViewBuilder
    private func saisie(_ exercice: ExerciceDeSeance) -> some View {
        if seance.seance?.proposition?.intermediaire == true {
            Label("Série intermédiaire : même nombre de répétitions, poids baissé.",
                  systemImage: "arrow.down.right")
                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
        }
        if exercice.enDuree {
            Compteur(titre: "Durée", valeur: $duree, pas: 5, bornes: 5...3600, unite: "s")
        } else if exercice.enDistance {
            Compteur(titre: "Distance", valeur: $distance, pas: 50, bornes: 10...50_000, unite: "m")
        } else {
            Compteur(titre: "Charge", valeur: $charge, pas: 2.5, bornes: 0...500, unite: "kg")
            Compteur(titre: "Répétitions", valeur: $reps, pas: 1, bornes: 1...100)
        }
        Button {
            seance.valider(charge: charge, reps: Int(reps), duree: Int(duree), distance: Int(distance), file: file)
            preRemplir()
        } label: {
            Text("Valider la série").frame(maxWidth: .infinity)
        }
        .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
        .sensoryFeedback(.success, trigger: seance.seance?.series.count)
        if !exercice.enDuree && !exercice.enDistance {
            Button("J'ai bloqué avant") { bloque = true }
                .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
        }
    }

    private var aucunExercice: some View {
        VStack(spacing: 12) {
            Image(systemName: "dumbbell").font(.system(size: 30)).foregroundStyle(Categorie.sport.couleur)
            Text("Choisis ton premier exercice").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
            Text("Ceux que tu as faits récemment passent en premier.")
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            Button("Chercher un exercice") { choisir = true }.buttonStyle(.hal(.accent))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .carte()
    }

    private func prevuEnClair(_ exercice: ExerciceDeSeance) -> String? {
        var morceaux: [String] = []
        if let series = exercice.series, let haut = exercice.repetitionsVisees {
            let bas = exercice.repetitionsMin ?? haut
            morceaux.append(bas == haut ? "\(series) × \(haut)" : "\(series) × \(bas) à \(haut)")
        }
        if let charge = exercice.chargeKg { morceaux.append(Poids.texte(charge)) }
        if let repos = exercice.reposSecondes { morceaux.append("repos \(repos) s") }
        return morceaux.isEmpty ? nil : "Prévu : " + morceaux.joined(separator: " · ")
    }

    private func preRemplir() {
        guard let exercice = seance.exerciceCourant else { return }
        let proposee = seance.proposee(pour: exercice)
        if let valeur = proposee.chargeKg { charge = valeur }
        if let valeur = proposee.repetitions { reps = Double(valeur) }
        if let valeur = proposee.dureeSecondes { duree = Double(valeur) }
        if let valeur = proposee.distanceM { distance = Double(valeur) }
    }
}

// MARK: - 3.7 Repos

/// Le repos entre deux séries, qui se compte tout seul. Un retour haptique à la fin.
private struct Repos: View {
    let fin: Date
    let duree: TimeInterval
    var passer: () -> Void
    @State private var fini = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { contexte in
            let reste = max(0, fin.timeIntervalSince(contexte.date))
            HStack(spacing: 14) {
                Anneau(valeur: duree > 0 ? reste / duree : 0, couleur: Categorie.sport.couleur, epaisseur: 6,
                       texte: String(format: "%d:%02d", Int(reste) / 60, Int(reste) % 60))
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repos").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                    Text("La série suivante est prête.").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                Spacer()
                Button("Passer", action: passer).buttonStyle(.hal(.verre))
            }
            .onChange(of: reste == 0) { _, termine in if termine { fini = true } }
        }
        .padding(Espace.interne)
        .carte()
        .sensoryFeedback(.success, trigger: fini)
    }
}

// MARK: - 3.6 Série bloquée

/// SAI-17 : à combien de répétitions on s'est arrêté.
private struct FeuilleBloque: View {
    let repsVisees: Int
    var valider: (Int) -> Void
    @Environment(\.dismiss) private var fermer
    @State private var faites: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Espace.gouttiere) {
            Text("J'ai bloqué avant").texte(.titre).foregroundStyle(Palette.textePrincipal)
            Text("La série est notée telle quelle. Une série intermédiaire suit, avec le poids un peu baissé.")
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            Compteur(titre: "Répétitions faites", valeur: $faites, pas: 1, bornes: 0...Double(max(0, repsVisees - 1)))
            Button("Noter la série") {
                valider(Int(faites))
                fermer()
            }
            .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
        }
        .padding(Espace.marge)
        .onAppear { faites = Double(max(0, repsVisees - 2)) }
    }
}

// MARK: - 3.8 Terminer ou arrêter

private enum FinDeSeance { case bilan, pasFaite }

/// SAI-15 : tout est saisi, arrêtée ici, faite sans rien saisir, ou pas faite.
private struct FeuilleTerminer: View {
    let prevue: Bool
    var choisir: (FinDeSeance) -> Void
    @Environment(\.dismiss) private var fermer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terminer la séance").texte(.titre).foregroundStyle(Palette.textePrincipal)
            choix("J'ai tout fait", "checkmark.circle", "Le bilan, puis HAL te répond.") { choisir(.bilan) }
            choix("J'arrête ici", "stop.circle", "Faite mais incomplète : seules les séries entrées comptent.") { choisir(.bilan) }
            choix("Faite, sans rien saisir", "circle.dashed", "Elle compte faite. Le bilan reste à donner.") { choisir(.bilan) }
            if prevue {
                choix("Pas faite", "xmark.circle", "HAL décide de la suite.") { choisir(.pasFaite) }
            }
        }
        .padding(Espace.marge)
    }

    private func choix(_ titre: String, _ icone: String, _ detail: String,
                       action: @escaping () -> Void) -> some View {
        Button {
            fermer()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icone).font(.system(size: 20)).foregroundStyle(Categorie.sport.couleur).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .verreControle(RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous))
    }
}

// MARK: - 3.9 Bilan

/// SAI-4 : l'effort de 1 à 10, la durée réelle, un commentaire. HAL répond
/// tout de suite si on le demande (SAI-7) ; sa réponse arrive dans son panneau.
struct EcranBilan: View {
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @Environment(\.annoncer) private var annoncer
    @State private var effort: Double = 7
    @State private var minutes: Double = 60
    @State private var commentaire = ""
    @State private var avisDeHAL = true

    var body: some View {
        FormulaireVerre {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Effort").foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        Text("\(Int(effort)) / 10").bold().foregroundStyle(Palette.textePrincipal)
                    }
                    Slider(value: $effort, in: 1...10, step: 1)
                    Text(libelleEffort).font(.footnote).foregroundStyle(Palette.texteSecondaire)
                }
                Stepper("Durée : \(Int(minutes)) min", value: $minutes, in: 5...300, step: 5)
            } header: {
                Text("Comment ça s'est passé")
            }
            Section("Un mot pour HAL") {
                TextField("Une douleur, une machine prise, une forme du jour…", text: $commentaire, axis: .vertical)
                    .lineLimit(2...5)
                Toggle("Avoir l'avis de HAL tout de suite", isOn: $avisDeHAL)
            }
            Section {
                Button {
                    seance.bilan(effort: Int(effort), minutes: Int(minutes), commentaire: commentaire,
                                 avisDeHAL: avisDeHAL, file: file)
                    annoncer(avisDeHAL ? "Séance close : HAL te répond dans son panneau" : "Séance close")
                } label: {
                    Text("Clore la séance").bold().frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Bilan")
        .navigationBarTitleDisplayMode(.inline)
        .background { Fond() }
        .onAppear { minutes = Double(max(5, (seance.minutesEcoulees + 4) / 5 * 5)) }
    }

    private var libelleEffort: String {
        switch Int(effort) {
        case ...3: "Facile, tu aurais pu en faire beaucoup plus"
        case 4...5: "Modéré"
        case 6...7: "Soutenu, il en restait un peu"
        case 8...9: "Dur, presque rien en réserve"
        default: "Maximal"
        }
    }
}

// MARK: - 3.10 Choisir un exercice

/// LIB-2 : chercher un exercice. Ceux faits récemment d'abord ; ceux qu'une
/// limitation interdit sont grisés (SEC-1). Le catalogue est gardé sur le
/// téléphone pour la salle sans réseau.
struct ChoixExercice: View {
    var choisir: (ExerciceCatalogue) -> Void
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var catalogue: [ExerciceCatalogue] = ChoixExercice.garde()
    @State private var recherche = ""

    var body: some View {
        NavigationStack {
            List {
                if catalogue.isEmpty {
                    Text("Catalogue indisponible sans réseau. Reconnecte-toi une fois pour le garder.")
                        .foregroundStyle(Palette.texteSecondaire)
                }
                ForEach(filtres) { exercice in
                    Button {
                        choisir(exercice)
                        fermer()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercice.libelle)
                                .foregroundStyle(exercice.interdit == true ? Palette.texteTertiaire : Palette.textePrincipal)
                            Text(exercice.interdit == true ? "Interdit par une limitation"
                                 : (exercice.groupePrincipal ?? "").replacingOccurrences(of: "_", with: " "))
                                .font(.footnote).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                    .disabled(exercice.interdit == true)
                    .listRowBackground(FondDeLigne())
                }
            }
            .scrollContentBackground(.hidden)
            .searchable(text: $recherche, prompt: "Développé, squat, rowing…")
            .navigationTitle("Ajouter un exercice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { fermer() } }
            }
            .task { await charger() }
        }
    }

    private var filtres: [ExerciceCatalogue] {
        let tries = catalogue.sorted { a, b in
            switch (a.derniereSaisie, b.derniereSaisie) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.libelle < b.libelle
            }
        }
        guard !recherche.isEmpty else { return tries }
        let cle = recherche.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return tries.filter {
            $0.libelle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(cle)
        }
    }

    private func charger() async {
        guard let lus: [ExerciceCatalogue] = try? await foyer.demander("GET", "exercices?discipline=musculation")
        else { return }
        catalogue = lus
        if let donnees = try? ClientAPI.encodeur.encode(lus) {
            try? donnees.write(to: Foyer.fichier("catalogue.json"), options: .atomic)
        }
    }

    private static func garde() -> [ExerciceCatalogue] {
        guard let donnees = try? Data(contentsOf: Foyer.fichier("catalogue.json")) else { return [] }
        return (try? ClientAPI.decodeur.decode([ExerciceCatalogue].self, from: donnees)) ?? []
    }
}
