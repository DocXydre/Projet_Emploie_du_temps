import Charts
import SwiftUI

// Les écrans du sport autour de la séance (lot 6b) : la semaine à valider, la
// santé, la fréquence du jour, les objectifs, la progression, l'annonce d'une
// séance libre et la séance à deux.

private let francais = Locale(identifier: "fr_FR")

private func jourCourt(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(francais))
}

private func motif(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

/// Un grand graphique, avec ses axes : les écrans détaillés en ont besoin.
private struct GrandeCourbe: View {
    let titre: String
    let unite: String
    let points: [PointSerie]
    var couleur: Color = Categorie.sport.couleur

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                Spacer()
                if let derniere = points.last(where: { $0.valeur != nil })?.valeur {
                    Text("\(Int(derniere.rounded())) \(unite)").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                }
            }
            if points.allSatisfy({ $0.valeur == nil }) {
                Text("Aucune donnée sur la période.").texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(points) { point in
                        if let valeur = point.valeur {
                            LineMark(x: .value("Jour", point.date), y: .value(titre, valeur))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(couleur)
                            PointMark(x: .value("Jour", point.date), y: .value(titre, valeur))
                                .foregroundStyle(couleur)
                                .symbolSize(18)
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Palette.texteTertiaire)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel().foregroundStyle(Palette.texteTertiaire)
                        AxisGridLine().foregroundStyle(Palette.verreSeparateur)
                    }
                }
                .frame(height: 160)
            }
        }
        .padding(Espace.interne)
        .carte()
    }
}

// MARK: - 3.2 Semaine à valider

struct EcranSemaine: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.annoncer) private var annoncer
    @State private var lundi: Date?
    @State private var semaine: SemaineDeSport?
    @State private var erreur: String?
    @State private var envoi = false

    init(lundi: Date? = nil) {
        _lundi = State(initialValue: lundi)
    }

    var body: some View {
        FormulaireVerre {
            if let semaine {
                Section {
                    HStack {
                        Button { decaler(-7) } label: { Image(systemName: "chevron.left") }
                        Spacer()
                        Text("Semaine du \(jourCourt(semaine.lundi))").bold()
                        Spacer()
                        Button { decaler(7) } label: { Image(systemName: "chevron.right") }
                    }
                    .buttonStyle(.borderless)
                    if let intention = semaine.intention, !intention.isEmpty {
                        AvisDeHAL(texte: intention)
                    }
                }
                ForEach(jours(semaine), id: \.self) { jour in
                    Section(jourCourt(jour)) {
                        ForEach(semaine.seances.filter { Calendar.current.isDate($0.jour, inSameDayAs: jour) }) { seance in
                            ligne(seance)
                        }
                    }
                }
                if semaine.seances.isEmpty {
                    Section { Text("Aucune séance cette semaine.").foregroundStyle(Palette.texteSecondaire) }
                }
                if let charge = semaine.charge, charge.chargeSeptJours != nil {
                    Section {
                        LabeledContent("Sur 7 jours", value: charge.chargeSeptJours.map { "\(Int($0))" } ?? "–")
                        LabeledContent("Moyenne par semaine sur 28 jours",
                                       value: charge.chargeQuatreSemaines.map { "\(Int($0 / 4))" } ?? "–")
                        if let rapport = charge.rapport {
                            LabeledContent("Rapport", value: rapport.formatted(
                                .number.precision(.fractionLength(2)).locale(francais)))
                        }
                        if let sans = charge.seancesSansBilan, sans > 0 {
                            Text("\(sans) séance\(sans > 1 ? "s" : "") sans bilan ne compte\(sans > 1 ? "nt" : "") pas.")
                                .font(.footnote).foregroundStyle(Palette.texteSecondaire)
                        }
                    } header: {
                        Text("Charge d'entraînement")
                    } footer: {
                        Text("La charge d'une séance, c'est l'effort noté au bilan multiplié par sa durée. Le rapport compare ta semaine à ta moyenne : il apparaît après quatre semaines.")
                    }
                }
                if let erreur {
                    Section { Label(erreur, systemImage: "exclamationmark.circle").foregroundStyle(Categorie.alerte.couleur) }
                }
                Section {
                    if semaine.aValider {
                        Button { Task { await valider() } } label: {
                            Text("Valider la semaine").bold().frame(maxWidth: .infinity)
                        }
                        .disabled(envoi)
                    } else if semaine.validee != nil {
                        Label("Semaine validée", systemImage: "checkmark.seal").foregroundStyle(Categorie.sport.couleur)
                    }
                    Button("Demander un changement") {
                        conversation.demanderUnChangement(ElementJoint(
                            genre: .semaine, lundi: semaine.lundi,
                            libelle: "Semaine du \(jourCourt(semaine.lundi))"))
                    }
                    .frame(maxWidth: .infinity)
                } footer: {
                    Text("Une validation pour toute la semaine. Un changement se demande à HAL : il refait la semaine et te la repropose.")
                }
            } else if let erreur {
                Section { Text(erreur).foregroundStyle(Palette.texteSecondaire) }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("La semaine")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL(semaine.map { "Semaine du \(jourCourt($0.lundi))" } ?? "La semaine")
        .task(id: lundi) { await charger() }
    }

    private func ligne(_ seance: SemaineDeSport.SeanceDeLaSemaine) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                let type = seance.typeSeance ?? ""
                Text(type.isEmpty || type == "libre" ? Discipline.nom(seance.discipline)
                     : type.prefix(1).uppercased() + type.dropFirst())
                    .foregroundStyle(Palette.textePrincipal)
                Text([seance.debut?.formatted(date: .omitted, time: .shortened),
                      seance.dureeMinutes.map { "\($0) min" }, seance.lieu,
                      seance.intensite].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Palette.texteSecondaire)
            }
            Spacer()
            Text(Self.situation(seance.situation)).font(.footnote).foregroundStyle(Palette.texteSecondaire)
        }
    }

    static func situation(_ code: String?) -> String {
        switch code {
        case "proposee": "à valider"
        case "validee": "validée"
        case "faite": "faite"
        case "pas_faite": "pas faite"
        case "esquisse": "esquisse"
        case "remplacee": "remplacée"
        case "retiree": "retirée"
        default: code ?? ""
        }
    }

    private func jours(_ semaine: SemaineDeSport) -> [Date] {
        let calendrier = Calendar.current
        var vus: [Date] = []
        for seance in semaine.seances {
            let jour = calendrier.startOfDay(for: seance.jour)
            if !vus.contains(jour) { vus.append(jour) }
        }
        return vus
    }

    private func decaler(_ jours: Int) {
        guard let base = semaine?.lundi else { return }
        lundi = Calendar.current.date(byAdding: .day, value: jours, to: base)
    }

    private func requete(_ chemin: String) -> String {
        guard let lundi else { return chemin }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return chemin + "?lundi=" + format.string(from: lundi)
    }

    private func charger() async {
        do {
            semaine = try await foyer.demander("GET", requete("appli/semaine"))
            erreur = nil
        } catch {
            erreur = motif(error)
        }
    }

    private func valider() async {
        envoi = true
        defer { envoi = false }
        do {
            try await foyer.agir("POST", requete("plan/semaine/valider"))
            annoncer("Semaine validée")
            await charger()
        } catch {
            erreur = motif(error)
        }
    }
}

// MARK: - 3.16 Sommeil et récupération

struct EcranSommeil: View {
    @Environment(Foyer.self) private var foyer
    @State private var periode = 30
    @State private var historique: HistoriqueSante?
    @State private var erreur: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                Segmente(choix: [(7, "7 jours"), (30, "30 jours"), (90, "90 jours")], selection: $periode)
                if let historique {
                    GrandeCourbe(titre: "Sommeil", unite: "min",
                                 points: historique.jours.map { PointSerie(date: $0.jour, valeur: $0.sommeilMinutes.map(Double.init)) },
                                 couleur: Categorie.linge.couleur)
                    GrandeCourbe(titre: "FC de repos", unite: "bpm",
                                 points: historique.jours.map { PointSerie(date: $0.jour, valeur: $0.fcRepos.map(Double.init)) },
                                 couleur: Categorie.alerte.couleur)
                    GrandeCourbe(titre: "Variabilité cardiaque", unite: "ms",
                                 points: historique.jours.map { PointSerie(date: $0.jour, valeur: $0.vfcMs) },
                                 couleur: Categorie.ia.couleur)
                    GrandeCourbe(titre: "Pas", unite: "",
                                 points: historique.jours.map { PointSerie(date: $0.jour, valeur: $0.pas.map(Double.init)) },
                                 couleur: Categorie.sport.couleur)
                    if !historique.seances.isEmpty {
                        EnTeteGroupe(texte: "Séances de la montre")
                        GroupeReglages {
                            ForEach(historique.seances.prefix(15), id: \.self) { activite in
                                LigneActivite(activite: activite)
                            }
                        }
                    }
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
                Text("Un jour sans donnée reste vide : ce n'est pas un zéro.")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire)
            }
            .padding(Espace.marge)
        }
        .navigationTitle("Sommeil et récupération")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Sommeil et récupération")
        .containerBackground(.clear, for: .navigation)
        .task(id: periode) {
            do {
                historique = try await foyer.demander("GET", "appli/sante?jours=\(periode)")
            } catch {
                erreur = motif(error)
            }
        }
    }
}

/// Une séance de la montre en une ligne : quoi, quand, combien.
private struct LigneActivite: View {
    let activite: HistoriqueSante.Activite

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Discipline.nom(activite.discipline ?? activite.type)).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Text(jourCourt(activite.debut)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            Spacer()
            Text(resume).texte(.legende).foregroundStyle(Palette.texteSecondaire)
        }
        .padding(.horizontal, Espace.interne)
        .padding(.vertical, 10)
    }

    private var resume: String {
        var morceaux: [String] = []
        if let duree = activite.dureeSecondes { morceaux.append("\(duree / 60) min") }
        if let distance = activite.distanceM { morceaux.append(String(format: "%.1f km", Double(distance) / 1000)) }
        if let fc = activite.fcMoyenne { morceaux.append("\(fc) bpm") }
        return morceaux.joined(separator: " · ")
    }
}

// MARK: - 3.15 La fréquence cardiaque du jour

struct EcranFrequence: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                let valeurs = foyer.frequenceDuJour.compactMap(\.valeur)
                HStack(spacing: Espace.gouttiere) {
                    Mesure(titre: "Maintenant", icone: "heart", valeur: valeurs.last.map { "\(Int($0))" }, unite: "bpm")
                    Mesure(titre: "Minimum", icone: "arrow.down", valeur: valeurs.min().map { "\(Int($0))" }, unite: "bpm")
                    Mesure(titre: "Maximum", icone: "arrow.up", valeur: valeurs.max().map { "\(Int($0))" }, unite: "bpm")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sur 24 heures").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                    Chart {
                        ForEach(foyer.frequenceDuJour) { point in
                            if let valeur = point.valeur {
                                AreaMark(x: .value("Heure", point.date), y: .value("bpm", valeur))
                                    .foregroundStyle(Categorie.alerte.voile)
                                    .interpolationMethod(.catmullRom)
                                LineMark(x: .value("Heure", point.date), y: .value("bpm", valeur))
                                    .foregroundStyle(Categorie.alerte.couleur)
                                    .interpolationMethod(.catmullRom)
                            }
                        }
                        ForEach(foyer.evenementsDuJour.filter { !$0.journeeEntiere }) { evenement in
                            RuleMark(x: .value("Heure", evenement.debut))
                                .foregroundStyle(evenement.categorie.couleur.opacity(0.5))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Palette.texteTertiaire)
                        }
                    }
                    .frame(height: 200)
                }
                .padding(Espace.interne)
                .carte()
                EnTeteGroupe(texte: "En face, la journée")
                GroupeReglages {
                    ForEach(foyer.evenementsDuJour.filter { !$0.journeeEntiere }) { evenement in
                        LigneEvenement(heure: evenement.debut.formatted(date: .omitted, time: .shortened),
                                       titre: evenement.titre, lieu: evenement.lieu,
                                       categorie: evenement.categorie,
                                       passe: (evenement.fin ?? evenement.debut) < .now)
                            .padding(.horizontal, Espace.interne)
                            .padding(.vertical, 8)
                    }
                }
                Text("Lue dans Santé, sur ce téléphone. Rien n'en part vers le serveur.")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire)
            }
            .padding(Espace.marge)
        }
        .navigationTitle("Fréquence cardiaque")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(.clear, for: .navigation)
    }
}

// MARK: - 3.18 Objectifs

struct EcranObjectifs: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation
    @State private var objectifs: [ObjectifDetaille]?
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            if let objectifs {
                if objectifs.isEmpty {
                    Section {
                        Text("Pas encore d'objectif. HAL t'en propose un au démarrage.")
                            .foregroundStyle(Palette.texteSecondaire)
                        Button("En parler à HAL") { conversation.ouvrir() }
                    }
                }
                ForEach(objectifs.filter { $0.statut == "actif" }) { objectif in
                    Section(objectif.principal ? "Objectif principal" : "Objectif secondaire") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(objectif.libelle).bold().foregroundStyle(Palette.textePrincipal)
                            if let echeance = objectif.echeance {
                                Text("Pour le \(jourCourt(echeance))").font(.footnote).foregroundStyle(Palette.texteSecondaire)
                            }
                        }
                        if let avis = objectif.avisDetail ?? objectif.avis {
                            AvisDeHAL(texte: avis)
                        }
                        if let feuille = objectif.feuilleDeRoute, !feuille.isEmpty {
                            Text(feuille).font(.callout).foregroundStyle(Palette.textePrincipal)
                        }
                    }
                }
                let anciens = objectifs.filter { $0.statut != "actif" }
                if !anciens.isEmpty {
                    Section("Terminés ou en pause") {
                        ForEach(anciens) { objectif in
                            HStack {
                                Text(objectif.libelle).foregroundStyle(Palette.textePrincipal)
                                Spacer()
                                Text(objectif.statut).font(.footnote).foregroundStyle(Palette.texteSecondaire)
                            }
                        }
                    }
                }
                Section {
                    Button("Changer d'objectif avec HAL") { conversation.ouvrir() }
                    .frame(maxWidth: .infinity)
                }
            } else if let erreur {
                Section { Text(erreur).foregroundStyle(Palette.texteSecondaire) }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Objectifs")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Objectifs")
        .task {
            do { objectifs = try await foyer.demander("GET", "objectifs") } catch { erreur = motif(error) }
        }
    }
}

// MARK: - 3.17 Progression

struct EcranProgression: View {
    @Environment(Foyer.self) private var foyer
    @State private var semaines: [SemaineDExercice]?
    @State private var erreur: String?
    @State private var choisi: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                if let semaines {
                    let codes = Self.exercices(semaines)
                    if codes.isEmpty {
                        Text("Rien encore : les séries saisies en séance apparaîtront ici, semaine par semaine.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    ForEach(codes.indices, id: \.self) { rang in
                        let code = codes[rang].0
                        let libelle = codes[rang].1
                        let siennes = semaines.filter { $0.code == code }
                        Button { choisi = choisi == code ? nil : code } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(libelle).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                    Spacer()
                                    if let meilleure = siennes.compactMap(\.meilleureCharge).max() {
                                        Text("record \(Poids.texte(meilleure))").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                    }
                                }
                                Courbe(points: siennes.map { PointSerie(date: $0.lundi, valeur: $0.meilleureCharge) },
                                       couleur: Categorie.sport.couleur, hauteur: choisi == code ? 140 : 50)
                                if choisi == code {
                                    ForEach(siennes.reversed(), id: \.self) { semaine in
                                        HStack {
                                            Text("Semaine du \(jourCourt(semaine.lundi))").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                            Spacer()
                                            Text([semaine.meilleureCharge.map(Poids.texte),
                                                  semaine.meilleuresRepetitions.map { "\($0) reps" },
                                                  semaine.series.map { "\($0) séries" }].compactMap { $0 }.joined(separator: " · "))
                                                .texte(.legende).foregroundStyle(Palette.textePrincipal)
                                        }
                                    }
                                }
                            }
                            .padding(Espace.interne)
                            .carte()
                        }
                        .buttonStyle(.plain)
                    }
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(Espace.marge)
        }
        .navigationTitle("Progression")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Progression")
        .containerBackground(.clear, for: .navigation)
        .task {
            do { semaines = try await foyer.demander("GET", "appli/progression") } catch { erreur = motif(error) }
        }
    }

    private static func exercices(_ semaines: [SemaineDExercice]) -> [(String, String)] {
        var vus: [(String, String)] = []
        for semaine in semaines where !vus.contains(where: { $0.0 == semaine.code }) {
            vus.append((semaine.code, semaine.libelle))
        }
        return vus
    }
}

// MARK: - 3.11 Annoncer une séance libre

/// LIB-3, LIB-4 : une séance qu'on fera à sa façon. HAL dit tout de suite ce
/// qu'il conseille d'éviter ce jour-là, et ajuste la suite.
struct FormulaireAnnonce: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var discipline = "musculation"
    @State private var debut = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0,
                                                     of: .now.addingTimeInterval(86_400)) ?? .now
    @State private var duree = 60
    @State private var texte = ""
    @State private var envoi = false
    @State private var reponse: String?
    @State private var erreur: String?

    private static let disciplines = [("musculation", "Musculation"), ("course", "Course"),
                                      ("velo", "Vélo"), ("natation", "Natation"), ("cardio", "Cardio")]

    var body: some View {
        FormulaireVerre {
            Section {
                Picker("Discipline", selection: $discipline) {
                    ForEach(Self.disciplines.indices, id: \.self) { rang in
                        Text(Self.disciplines[rang].1).tag(Self.disciplines[rang].0)
                    }
                }
                DatePicker("Quand", selection: $debut, in: Date.now...)
                Stepper("Durée : \(duree) min", value: $duree, in: 15...240, step: 15)
            }
            Section("Ce que tu comptes faire, si tu le sais") {
                TextField("Jambes, ou un footing tranquille…", text: $texte, axis: .vertical).lineLimit(2...4)
            }
            if let reponse {
                Section("HAL") { Text(reponse).foregroundStyle(Palette.textePrincipal) }
            }
            if let erreur {
                Section { Label(erreur, systemImage: "exclamationmark.circle").foregroundStyle(Categorie.alerte.couleur) }
            }
            Section {
                if reponse == nil {
                    Button { Task { await envoyer() } } label: {
                        HStack { Spacer(); if envoi { ProgressView() } else { Text("Annoncer").bold() }; Spacer() }
                    }
                    .disabled(envoi)
                } else {
                    Button("Fermer") { fermer() }.frame(maxWidth: .infinity)
                }
            } footer: {
                Text("Elle compte dans la charge de la semaine. HAL ne la refuse pas.")
            }
        }
        .navigationTitle("Annoncer une séance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Demande: Encodable {
        let discipline: String
        let debut: Date
        let dureeMinutes: Int
        let texte: String?
        let cleClient: UUID
    }

    private struct Reponse: Decodable, Sendable {
        struct Coach: Decodable, Sendable { let message: String? }
        let coach: Coach?
    }

    private func envoyer() async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            let rendu: Reponse = try await foyer.demander(
                "POST", "seances/libre/annoncer",
                corps: ClientAPI.corps(Demande(discipline: discipline, debut: debut, dureeMinutes: duree,
                                               texte: texte.isEmpty ? nil : texte, cleClient: UUID())))
            reponse = rendu.coach?.message ?? "C'est noté."
            annoncer("Séance annoncée")
            await foyer.charger()
        } catch {
            erreur = motif(error)
        }
    }
}

// MARK: - 3.20 Séance à deux

/// SPT-31, SPT-32 : l'autre propose de venir. Venir pose la même séance.
struct BandeauInvitation: View {
    let invitation: EtatSport.InvitationAPI
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var envoi = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(invitation.qui) va au sport", systemImage: "person.2")
                .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            Text([invitation.debut.formatted(.dateTime.weekday(.wide).hour().minute().locale(francais)),
                  invitation.lieu].compactMap { $0 }.joined(separator: " · "))
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            HStack {
                Button("Je viens") { repondre(true) }.buttonStyle(.hal(.accent, pleineLargeur: true))
                Button("Pas cette fois") { repondre(false) }.buttonStyle(.hal(.verre))
            }
            .disabled(envoi)
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte()
    }

    private struct Reponse: Encodable { let vient: Bool }

    private func repondre(_ vient: Bool) {
        envoi = true
        Task {
            defer { envoi = false }
            do {
                try await foyer.agir("POST", "seances/invitations/\(invitation.id)/repondre",
                                     corps: ClientAPI.corps(Reponse(vient: vient)))
                annoncer(vient ? "C'est noté, la séance est posée" : "Une autre fois")
            } catch {
                annoncer(motif(error))
            }
        }
    }
}
