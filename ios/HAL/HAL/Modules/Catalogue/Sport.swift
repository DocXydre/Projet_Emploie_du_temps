import SwiftUI

extension Module {
    static let sport = Module(
        id: "sport", nom: "Sport", icone: "figure.run", categorie: .sport,
        tailles: [.petit, .moyen],
        widget: { taille in AnyView(WidgetSport(taille: taille)) },
        agrandi: { AnyView(VueSeanceDuJour()) },
        pourHAL: { foyer in "Séances : \(foyer.semaine.faites) sur \(foyer.semaine.prevues)" }
    )

    static let forme = Module(
        id: "forme", nom: "Forme", icone: "heart", categorie: .alerte,
        tailles: [.moyen, .petit],
        widget: { taille in AnyView(WidgetForme(taille: taille)) }
    )

    static let objectif = Module(
        id: "objectif", nom: "Objectif", icone: "target", categorie: .sport,
        tailles: [.petit],
        widget: { _ in AnyView(WidgetObjectif()) }
    )

    static let frequenceDuJour = Module(
        id: "frequenceDuJour", nom: "Fréquence cardiaque · aujourd'hui", icone: "waveform", categorie: .alerte,
        tailles: [.moyen], avecMontre: true,
        widget: { _ in AnyView(WidgetFrequence()) }
    )

    /// Toujours en bas à droite d'Aujourd'hui : l'entrée d'une séance non prévue (WID-7).
    static let seanceLibre = Module(
        id: "seanceLibre", nom: "Séance libre", icone: "plus", categorie: .sport,
        tailles: [.petit], fixe: true,
        widget: { _ in AnyView(WidgetSeanceLibre()) }
    )

    static let lancerSeance = Module(
        id: "lancerSeance", nom: "Séance du jour", icone: "dumbbell", categorie: .sport,
        tailles: [.moyen],
        widget: { _ in AnyView(WidgetLancerSeance()) },
        agrandi: { AnyView(VueSeanceDuJour()) }
    )

    static let mesureDemandee = Module(
        id: "mesureDemandee", nom: "Mesure demandée", icone: "scalemass", categorie: .ia,
        tailles: [.moyen],
        widget: { _ in AnyView(WidgetMesureDemandee()) }
    )
}

struct WidgetSport: View {
    let taille: TailleWidget
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.sport) {
            let semaine = foyer.semaine
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Anneau(valeur: Double(semaine.faites) / Double(max(1, semaine.prevues)),
                           texte: "\(semaine.faites)/\(semaine.prevues)")
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(semaine.faites) / \(semaine.prevues)").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                        Text("séances").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                }
                Spacer(minLength: 0)
                if let prochaine = semaine.prochaine {
                    Text("Prochaine").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    Text(prochaine).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                }
            }
        }
    }
}

struct WidgetForme: View {
    let taille: TailleWidget
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.forme) {
            let forme = foyer.forme
            if taille == .petit {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sommeil(forme.sommeilMinutes)).texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                    Text(foyer.aUneMontre ? "de sommeil" : "de sommeil estimé").texte(.legende)
                        .foregroundStyle(Palette.texteSecondaire)
                }
            } else if foyer.aUneMontre {
                HStack(alignment: .top) {
                    valeur("Sommeil", sommeil(forme.sommeilMinutes))
                    valeur("FC repos", forme.fcRepos.map(String.init) ?? "—", "bpm")
                    valeur("VFC", forme.vfc.map(String.init) ?? "—", "ms")
                }
            } else {
                // MON-8, MON-14 : sans montre, le sommeil que l'iPhone estime et les pas.
                HStack(alignment: .top) {
                    valeur("Sommeil estimé", sommeil(forme.sommeilMinutes))
                    valeur("Pas", forme.pas.map(EnFrancais.nombre) ?? "—")
                }
            }
        }
    }

    private func sommeil(_ minutes: Int?) -> String {
        guard let minutes else { return "—" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    private func valeur(_ titre: String, _ texte: String, _ unite: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(texte).texte(.titre).foregroundStyle(Palette.textePrincipal)
                if texte != "—" && !unite.isEmpty {
                    Text(unite).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WidgetObjectif: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation

    var body: some View {
        CoquilleWidget(.objectif) {
            if let objectif = foyer.objectifEnCours {
                VStack(alignment: .leading, spacing: 6) {
                    Text(objectif.titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal).lineLimit(2)
                    Spacer(minLength: 0)
                    Text("J−\(objectif.joursRestants)").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                    ProgressView(value: objectif.avancee).tint(Categorie.sport.couleur)
                }
            } else if foyer.demarrageDeHAL != nil {
                VideWidget(texte: "Pas encore d'objectif.", bouton: "Démarrer HAL") {
                    conversation.demarrageOuvert = true
                }
            } else {
                VideWidget(texte: "Pas d'objectif en cours : dis à HAL ce que tu vises.")
            }
        }
    }
}

struct WidgetFrequence: View {
    @Environment(Foyer.self) private var foyer
    @Environment(EnvoiSante.self) private var sante

    var body: some View {
        CoquilleWidget(.frequenceDuJour) {
            let valeurs = foyer.frequenceDuJour.compactMap(\.valeur)
            // WID-8 : sans données, le widget dit d'où elles viennent, et comment les avoir.
            if valeurs.isEmpty {
                if sante.disponible && !sante.accesDemande {
                    VideWidget(texte: "La fréquence cardiaque vient de Santé.", bouton: "Autoriser Santé") {
                        Task { await sante.demanderAcces() }
                    }
                } else {
                    VideWidget(texte: "Pas encore de fréquence cardiaque aujourd'hui. La montre la remplit au fil de la journée.")
                }
            } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(valeurs.last.map { String(Int($0)) } ?? "—").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                    Text("bpm maintenant").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    Spacer()
                    if let minimum = valeurs.min(), let maximum = valeurs.max() {
                        Text("min \(Int(minimum)) · max \(Int(maximum))").texte(.legende).foregroundStyle(Palette.texteTertiaire)
                    }
                }
                Courbe(points: foyer.frequenceDuJour, hauteur: 70)
            }
            }
        }
    }
}

struct WidgetSeanceLibre: View {
    @Environment(\.theme) private var theme
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file

    var body: some View {
        Button { seance.lancerLibre(file: file) } label: { contenu }
            .buttonStyle(.plain)
    }

    private var contenu: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.surPrincipal)
                .frame(width: 64, height: 64)
                .background(theme.principal, in: Circle())
            Text(seance.enCours ? "Séance en cours" : "Séance libre").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            Text(seance.enCours ? "la reprendre" : "chercher un exercice").texte(.legende).foregroundStyle(Palette.texteSecondaire)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .carte()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Le jour d'une séance de musculation, en tête d'Aujourd'hui (WID-6).
struct WidgetLancerSeance: View {
    @Environment(Foyer.self) private var foyer
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @Environment(\.annoncer) private var annoncer
    @State private var supprimer = false

    var body: some View {
        let jour = foyer.seanceAPrevoir ?? foyer.seance
        CoquilleWidget(titre: "Séance du jour · \(jour.heure)", icone: "dumbbell", couleur: Categorie.sport.couleur) {
            VStack(alignment: .leading, spacing: 6) {
                Text(jour.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                Text("\(jour.exercices.count) exercices · \(jour.duree)")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                Spacer(minLength: 0)
                HStack {
                    Button(seance.enCours ? "Reprendre" : "Lancer la séance") {
                        if let detail = foyer.seanceDuJour { seance.lancer(detail) } else { seance.affichee = seance.enCours }
                    }
                    .buttonStyle(.hal(.accent, pleineLargeur: true))
                    if !seance.enCours, let detail = foyer.seanceDuJour {
                        if detail.seance.libre == true && detail.saisi.isEmpty {
                            // SAI-19 : une séance libre ouverte par erreur, sans rien dedans.
                            Button("Supprimer") { supprimer = true }
                                .buttonStyle(.hal(.verre))
                        } else {
                            Button("Déjà faite") {
                                SeanceEnCours.dejaFaite(detail, file: file)
                                annoncer("Séance comptée faite")
                            }
                            .buttonStyle(.hal(.verre))
                        }
                    }
                }
            }
        }
        .confirmationDialog("Supprimer cette séance libre ?", isPresented: $supprimer, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                guard let id = foyer.seanceDuJour?.seance.idOccurrence else { return }
                Task {
                    do {
                        try await foyer.agir("DELETE", "seances/\(id)/libre")
                        annoncer("Séance libre supprimée")
                    } catch {
                        annoncer((error as? ErreurAPI)?.message ?? "Suppression impossible")
                    }
                }
            }
        } message: {
            Text("Elle a été lancée par erreur : elle disparaît, sans rien laisser.")
        }
    }
}

/// 1.7 : la séance du jour en grand. Son titre et son jour, la durée,
/// l'intensité et les groupes, chaque exercice avec son matériel, son repos, ses
/// séries et sa charge, la consigne de HAL. « Commencer » la lance ; « Déplacer »
/// passe par HAL, qui seul change une séance (COA-32).
struct VueSeanceDuJour: View {
    @Environment(Foyer.self) private var foyer
    @Environment(SeanceEnCours.self) private var seance
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.fermerAgrandi) private var fermerAgrandi

    var body: some View {
        if let detail = foyer.seanceDuJour {
            detaillee(detail)
        } else {
            apercu(foyer.seanceAPrevoir ?? foyer.seance)
        }
    }

    private func detaillee(_ detail: DetailSeance) -> some View {
        CoquilleWidget(titre: "Sport · Séance du jour", icone: "waveform.path.ecg", couleur: Categorie.sport.couleur) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text(detail.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                        if detail.seance.cle == true {
                            Puce("Clé", categorie: .sport)
                        }
                    }
                    Text(sousTitre(detail.seance)).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    Flux(espacement: 6) {
                        if let minutes = detail.seance.dureeMinutes {
                            puce("timer", EnFrancais.duree(minutes: minutes))
                        }
                        if let intensite = detail.seance.intensite {
                            puce("flame", Self.intensite(intensite))
                        }
                        if let groupes = detail.seance.groupes, !groupes.isEmpty {
                            let texte = groupes.prefix(3).map(Self.groupe).joined(separator: ", ")
                            puce("scope", texte.prefix(1).uppercased() + texte.dropFirst())
                        }
                    }
                    Divider().overlay(Palette.verreBord)
                    ForEach(Array(detail.prevu.enumerated()), id: \.element.id) { rang, ligne in
                        exercice(rang + 1, ligne)
                    }
                    if let consigne = detail.seance.consigne, !consigne.isEmpty {
                        Divider().overlay(Palette.verreBord)
                        HStack(alignment: .top, spacing: 10) {
                            Orbe(etat: .repos, taille: 22)
                            Text(consigne).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            HStack {
                Button(seance.enCours ? "Reprendre la séance" : "Commencer la séance") {
                    fermerAgrandi?.fermer()
                    seance.lancer(detail)
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                Button("Déplacer") {
                    fermerAgrandi?.fermer()
                    conversation.demanderUnChangement(ElementJoint(
                        genre: .seance, idOccurrence: detail.seance.idOccurrence, libelle: detail.titre))
                }
                .buttonStyle(.hal(.verre, grand: true))
            }
        }
        .frame(maxHeight: 620)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func exercice(_ numero: Int, _ ligne: LignePrevue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(numero)").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                .frame(width: 24, height: 24)
                .background(Palette.verreTeinte, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(ligne.libelle).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(sousLigne(ligne)).texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(volume(ligne)).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Text(ligne.chargeKg.map(Poids.texte) ?? "au ressenti")
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
        }
    }

    /// Avant que le serveur ait répondu, ou sans serveur : le résumé des données fictives.
    private func apercu(_ jour: SeanceDuJour) -> some View {
        CoquilleWidget(titre: "Sport · Séance du jour", icone: "waveform.path.ecg", couleur: Categorie.sport.couleur) {
            VStack(alignment: .leading, spacing: 10) {
                Text(jour.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                ForEach(jour.exercices.indices, id: \.self) { rang in
                    HStack {
                        Text("\(rang + 1)").texte(.corpsFort).foregroundStyle(Palette.texteTertiaire).frame(width: 20)
                        Text(jour.exercices[rang]).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    }
                }
                if !jour.consigne.isEmpty {
                    AvisDeHAL(texte: jour.consigne, style: .legende, secondaire: true)
                }
            }
        }
        .frame(height: 340)
    }

    private func puce(_ icone: String, _ texte: String) -> some View {
        Label(texte, systemImage: icone)
            .texte(.legende).foregroundStyle(Palette.textePrincipal)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Palette.verreTeinte, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.verreBord, lineWidth: 0.5))
    }

    /// « Jeu. 15 oct. · 18:30 · Salle de musculation »
    private func sousTitre(_ seance: DetailSeance.Seance) -> String {
        var morceaux: [String] = []
        if let jour = seance.jour ?? seance.debut {
            let texte = EnFrancais.jour(jour)
            morceaux.append(texte.prefix(1).uppercased() + texte.dropFirst())
        }
        if let debut = seance.debut { morceaux.append(EnFrancais.heure(debut)) }
        if let lieu = seance.lieu { morceaux.append(lieu) }
        return morceaux.joined(separator: " · ")
    }

    /// « Barre · repos 2 min »
    private func sousLigne(_ ligne: LignePrevue) -> String {
        var morceaux: [String] = []
        if let materiel = ligne.materiel { morceaux.append(EnFrancais.materiel(materiel)) }
        if let repos = ligne.reposSecondes {
            morceaux.append(repos % 60 == 0 && repos >= 60 ? "repos \(repos / 60) min" : "repos \(repos) s")
        }
        return morceaux.joined(separator: " · ")
    }

    /// « 4 × 6 », « 3 × 8-10 », « 1 × 30 min »
    private func volume(_ ligne: LignePrevue) -> String {
        let series = ligne.series ?? 1
        if let minimum = ligne.repetitionsMin, let maximum = ligne.repetitionsMax {
            return minimum == maximum ? "\(series) × \(minimum)" : "\(series) × \(minimum)-\(maximum)"
        }
        if let secondes = ligne.dureeSecondes { return "\(series) × \(EnFrancais.duree(minutes: secondes / 60))" }
        if let metres = ligne.distanceM { return "\(series) × \(EnFrancais.distance(metres))" }
        return "\(series) séries"
    }

    static func intensite(_ code: String) -> String {
        switch code {
        case "legere": "Légère"
        case "moderee": "Modérée"
        case "dure": "Dure"
        default: code.capitalized
        }
    }

    /// Court, pour tenir dans une puce : « Pecs, dos, épaules ».
    static func groupe(_ code: String) -> String {
        switch code {
        case "pectoraux": "pecs"
        case "abdominaux": "abdos"
        case "ischios": "ischios"
        default: EnFrancais.groupe(code).lowercased()
        }
    }
}

/// Une fenêtre de mesure ouverte par HAL (MES-1).
struct WidgetMesureDemandee: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var saisir = false

    var body: some View {
        let mesure = foyer.mesureDemandee ?? foyer.mesureEnCours
        CoquilleWidget(titre: "Mesure demandée · \(mesure.jusquA)", icone: "scalemass", couleur: Categorie.ia.couleur) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mesure.titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                Text(mesure.consigne).texte(.corps).foregroundStyle(Palette.texteSecondaire).lineLimit(2)
                Spacer(minLength: 0)
                HStack {
                    Button("Saisir") { saisir = true }.buttonStyle(.hal(.accent, pleineLargeur: true))
                    Button("Pas possible") { reporter(mesure) }.buttonStyle(.hal(.verre))
                }
            }
        }
        .sheet(isPresented: $saisir) {
            FeuilleMesure(mesure: mesure).presentationDetents([.fraction(0.8), .large]).feuilleEnVerre()
        }
    }

    /// MES-3 : « Je ne peux pas » repousse la fenêtre, sans reproche.
    private func reporter(_ mesure: MesureDemandee) {
        guard foyer.connecte else {
            foyer.essais.mesure = false
            return
        }
        Task {
            do {
                try await foyer.agir("POST", "mesures/fenetres/\(mesure.id)/reporter")
                annoncer("Mesure repoussée")
            } catch {
                annoncer((error as? ErreurAPI)?.message ?? "Impossible pour l'instant")
            }
        }
    }
}

/// 3.19 : saisir une mesure. Ouverte par une fenêtre de HAL, son type est
/// fixé et « Je ne peux pas » la repousse ; ouverte depuis Mesures (`id` à 0),
/// on choisit le type (MES-4). La valeur part de la dernière saisie. Un test de
/// course se donne en minutes et secondes, sur deux roues comme le minuteur d'iOS.
struct FeuilleMesure: View {
    let mesure: MesureDemandee
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var type = "poids"
    @State private var cote = "droite"
    @State private var valeur: Double = 70
    @State private var minutes = 15
    @State private var secondes = 0
    @State private var date = Date.now
    @State private var historique: [MesureSaisie] = []
    @State private var envoi = false
    @State private var erreur: String?

    private var libre: Bool { mesure.id == 0 }
    private var unite: String { TypeMesure.unite(type) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                HStack {
                    Text("Saisir une mesure").texte(.titre).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    BoutonRond("xmark", libelle: "Fermer") { fermer() }
                }
                if libre {
                    EnTeteGroupe(texte: "Type")
                    Flux {
                        ForEach(TypeMesure.tous, id: \.self) { choix in
                            PuceChoix(texte: TypeMesure.court(choix), choisie: choix == type) {
                                withAnimation(.snappy) { type = choix }
                            }
                        }
                    }
                }
                if TypeMesure.parCote(type) {
                    EnTeteGroupe(texte: "Côté")
                    Segmente(choix: [("gauche", "Gauche"), ("droite", "Droite")], selection: $cote)
                }
                saisie
                HStack {
                    Text("Date").texte(.corps).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "fr_FR"))
                }
                .padding(.horizontal, Espace.interne)
                .padding(.vertical, 10)
                .carte(rayon: Rayon.controle)
                if !libre {
                    Label {
                        Text("Mesure demandée par HAL \(mesure.jusquA)" + (mesure.consigne.isEmpty ? "" : " : \(mesure.consigne)"))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .padding(Espace.interne)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: Rayon.controle)
                }
                if let erreur {
                    Label(erreur, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Categorie.alerte.couleur)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(envoi ? "Envoi…" : "Enregistrer") { Task { await enregistrer() } }
                    .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                    .disabled(envoi || (unite == "s" && minutes * 60 + secondes <= 0))
                if !libre {
                    Button("Je ne peux pas cette fois") { Task { await reporter() } }
                        .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
                        .disabled(envoi)
                }
            }
            .padding(Espace.marge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            type = mesure.type
            await chargerHistorique()
            partirDeLaDerniere()
        }
        .onChange(of: type) { partirDeLaDerniere() }
        .onChange(of: cote) { partirDeLaDerniere() }
    }

    @ViewBuilder private var saisie: some View {
        switch unite {
        case "s":
            HStack(spacing: 0) {
                roue("Minutes", selection: $minutes, valeurs: 0...180, suffixe: "min")
                roue("Secondes", selection: $secondes, valeurs: 0...59, suffixe: "s")
            }
            .frame(height: 170)
            .padding(.horizontal, Espace.serre)
            .carte(rayon: Rayon.controle)
        case "reps":
            Compteur(titre: "Répétitions", valeur: $valeur, pas: 1, bornes: 1...500)
        case "kg":
            Compteur(titre: "Poids", valeur: $valeur, pas: 0.1, bornes: 20...300, unite: "kg", saisie: true)
        default:
            Compteur(titre: TypeMesure.libelle(type), valeur: $valeur, pas: 0.5, bornes: 10...200, unite: "cm")
        }
    }

    /// La dernière mesure du même type, et du même côté s'il y en a un.
    private func partirDeLaDerniere() {
        let derniere = historique.first {
            $0.typeMesure == type && (!TypeMesure.parCote(type) || $0.cote == cote)
        }
        if let derniere {
            if unite == "s" {
                let total = Int(derniere.valeur.rounded())
                minutes = total / 60
                secondes = total % 60
            } else {
                valeur = derniere.valeur
            }
            return
        }
        switch unite {
        case "kg": valeur = 70
        case "reps": valeur = 10
        case "s": minutes = 15; secondes = 0
        default: valeur = 40
        }
    }

    private func chargerHistorique() async {
        guard foyer.connecte else { return }
        historique = (try? await foyer.demander("GET", "appli/mesures")) ?? []
    }

    private func roue(_ titre: String, selection: Binding<Int>, valeurs: ClosedRange<Int>,
                      suffixe: String) -> some View {
        Picker(titre, selection: selection) {
            ForEach(Array(valeurs), id: \.self) { nombre in
                Text("\(nombre) \(suffixe)").foregroundStyle(Palette.textePrincipal).tag(nombre)
            }
        }
        .pickerStyle(.wheel)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private struct Envoi: Encodable {
        let type: String
        let valeur: Double
        let unite: String
        let cote: String?
        let dateMesure: String
    }

    private func enregistrer() async {
        guard foyer.connecte else {
            foyer.essais.mesure = false
            fermer()
            return
        }
        envoi = true
        defer { envoi = false }
        let nombre = unite == "s" ? Double(minutes * 60 + secondes) : (valeur * 10).rounded() / 10
        do {
            try await foyer.agir("POST", "mesures", corps: ClientAPI.corps(Envoi(
                type: type, valeur: nombre, unite: unite,
                cote: TypeMesure.parCote(type) ? cote : nil,
                dateMesure: TexteHAL.jourISO(date))))
            annoncer("Mesure enregistrée")
            fermer()
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }

    /// MES-3 : « Je ne peux pas » repousse la fenêtre, sans reproche.
    private func reporter() async {
        guard foyer.connecte else {
            foyer.essais.mesure = false
            fermer()
            return
        }
        envoi = true
        defer { envoi = false }
        do {
            try await foyer.agir("POST", "mesures/fenetres/\(mesure.id)/reporter")
            annoncer("Mesure repoussée")
            fermer()
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
