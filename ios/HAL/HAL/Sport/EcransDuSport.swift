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

// MARK: - 3.2 Semaine à valider

struct EcranSemaine: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.annoncer) private var annoncer
    @State private var lundi: Date?
    @State private var semaine: SemaineDeSport?
    @State private var erreur: String?
    @State private var envoi = false
    @State private var ouverte: DetailSeance?

    init(lundi: Date? = nil) {
        _lundi = State(initialValue: lundi)
    }

    @Environment(\.dismiss) private var fermer

    /// 3.2 : sur la photo. L'avis de HAL et le rôle de la semaine, les sept jours
    /// dans une carte, puis « Valider la semaine » d'un geste (PLN-6) et
    /// « Demander un changement à HAL » (COA-32).
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                barre
                if let semaine {
                    resume(semaine)
                    jours(semaine)
                    if let erreur {
                        Label(erreur, systemImage: "exclamationmark.circle")
                            .texte(.corps).foregroundStyle(Categorie.alerte.couleur)
                    }
                    if semaine.aValider {
                        Button { Task { await valider() } } label: {
                            HStack {
                                if envoi { ProgressView() }
                                Text("Valider la semaine")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                        .disabled(envoi)
                    } else if semaine.validee != nil {
                        Label("Semaine validée", systemImage: "checkmark.seal.fill")
                            .texte(.corpsFort).foregroundStyle(Categorie.sport.couleur)
                            .frame(maxWidth: .infinity)
                    }
                    Button("Demander un changement à HAL") {
                        conversation.demanderUnChangement(ElementJoint(
                            genre: .semaine, lundi: semaine.lundi,
                            libelle: "Semaine du \(jourCourt(semaine.lundi))"))
                    }
                    .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
        .vuParHAL(semaine.map { "Semaine du \(jourCourt($0.lundi))" } ?? "La semaine")
        .task(id: lundi) { await charger() }
        .sheet(item: $ouverte, onDismiss: { Task { await charger() } }) { detail in
            EcranSeancePrevue(detail: detail)
        }
    }

    /// Retour, « Semaine du 19 oct. », et les flèches vers la semaine d'avant et d'après.
    private var barre: some View {
        ZStack {
            Text(semaine.map { "Semaine du \($0.lundi.formatted(.dateTime.day().month(.abbreviated).locale(francais)))" }
                 ?? "La semaine")
                .texte(.titreWidget).foregroundStyle(Palette.textePrincipal).surLaPhoto()
            HStack(spacing: 8) {
                BoutonRond("chevron.left", libelle: "Retour") { fermer() }
                Spacer()
                BoutonRond("arrow.left", libelle: "Semaine d'avant") { decaler(-7) }
                BoutonRond("arrow.right", libelle: "Semaine d'après") { decaler(7) }
            }
        }
        .frame(height: 44)
        .padding(.top, Espace.serre)
    }

    /// L'avis de HAL : l'intention de la semaine, ou son résumé, et son rôle.
    private func resume(_ semaine: SemaineDeSport) -> some View {
        let actives = semaine.seances.filter { !["retiree", "remplacee"].contains($0.situation ?? "") }
        let minutes = actives.compactMap(\.dureeMinutes).reduce(0, +)
        let role = TexteHAL.role(semaine.role)
        let texte = semaine.intention.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Semaine\(role.isEmpty ? "" : " de \(role)") : \(actives.count) séance\(actives.count > 1 ? "s" : ""), \(EnFrancais.duree(minutes: minutes)) au total."
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Orbe(etat: .repos, taille: 22)
                Text(texte).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if !role.isEmpty { Puce(role.prefix(1).uppercased() + role.dropFirst(), categorie: .sport) }
                if semaine.aValider {
                    Puce(texte: "À valider")
                } else if let validee = semaine.validee {
                    Puce(texte: "Validée le \(jourCourt(validee))")
                }
            }
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: Rayon.controle)
    }

    /// Les sept jours, du lundi au dimanche ; un jour sans séance est un repos.
    private func jours(_ semaine: SemaineDeSport) -> some View {
        let calendrier = Calendar.current
        let lesSept = (0..<7).compactMap { calendrier.date(byAdding: .day, value: $0, to: semaine.lundi) }
        return VStack(spacing: 0) {
            ForEach(Array(lesSept.enumerated()), id: \.offset) { rang, jour in
                let seances = semaine.seances.filter {
                    calendrier.isDate($0.jour, inSameDayAs: jour) && !["retiree", "remplacee"].contains($0.situation ?? "")
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Text(jour.formatted(.dateTime.weekday(.abbreviated).locale(francais)).capitalized)
                            .texte(.legende)
                        Text(jour.formatted(.dateTime.day())).texte(.corpsFort)
                    }
                    .foregroundStyle(seances.isEmpty ? Palette.texteTertiaire : Palette.textePrincipal)
                    .frame(width: 40)
                    if seances.isEmpty {
                        Text("Repos").texte(.corps).foregroundStyle(Palette.texteTertiaire)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(seances) { seance in
                                Button { Task { await ouvrir(seance.idOccurrence) } } label: { ligne(seance) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, Espace.interne)
                .padding(.vertical, 10)
                if rang < 6 { Divider().overlay(Palette.verreBord) }
            }
        }
        .carte(rayon: Rayon.controle)
    }

    private func ouvrir(_ id: Int) async {
        do {
            ouverte = try await foyer.demander("GET", "seances/\(id)")
        } catch {
            erreur = motif(error)
        }
    }

    private func ligne(_ seance: SemaineDeSport.SeanceDeLaSemaine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                let type = seance.typeSeance ?? ""
                Text(type.isEmpty || type == "libre" ? Discipline.nom(seance.discipline)
                     : type.prefix(1).uppercased() + type.dropFirst())
                    .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Text([seance.debut.map(EnFrancais.heure), seance.lieu,
                      seance.dureeMinutes.map { EnFrancais.duree(minutes: $0) }].compactMap { $0 }
                        .joined(separator: " · "))
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if seance.situation == "faite" {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Categorie.sport.couleur)
            } else if seance.situation != "proposee" {
                Puce(texte: Self.situation(seance.situation))
            }
        }
        .contentShape(Rectangle())
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

/// 3.16 : la VFC en courbe, le sommeil en barres, la FC de repos et les pas,
/// sur 7, 30 ou 90 jours. Un jour sans donnée reste vide (SAN-5).
struct EcranSommeil: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var periode = 7
    @State private var historique: HistoriqueSante?
    @State private var erreur: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                ZStack {
                    Text("Sommeil et récupération").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                        .surLaPhoto()
                    HStack {
                        BoutonRond("chevron.left", libelle: "Retour") { fermer() }
                        Spacer()
                    }
                }
                .frame(height: 44)
                Segmente(choix: [(7, "7 j"), (30, "30 j"), (90, "90 j")], selection: $periode)
                if let historique {
                    carteVFC(historique.jours)
                    carteSommeil(historique.jours)
                    HStack(spacing: Espace.gouttiere) {
                        tuile("FC repos", "heart", Categorie.alerte.couleur,
                              historique.jours.last?.fcRepos.map(String.init), "bpm",
                              ecart(historique.jours.compactMap { $0.fcRepos.map(Double.init) }).map {
                                  "\($0 >= 0 ? "+" : "−")\(Int(abs($0).rounded())) en \(periode) j"
                              })
                        tuile("Pas / jour", "shoeprints.fill", Categorie.sport.couleur,
                              moyenne(historique.jours.compactMap { $0.pas.map(Double.init) })
                                  .map { EnFrancais.nombre(Int($0.rounded())) }, nil,
                              "moyenne \(periode) j")
                    }
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
        .vuParHAL("Sommeil et récupération")
        .task(id: periode) {
            do {
                historique = try await foyer.demander("GET", "appli/sante?jours=\(periode)")
            } catch {
                erreur = motif(error)
            }
        }
    }

    private func moyenne(_ valeurs: [Double]) -> Double? {
        valeurs.isEmpty ? nil : valeurs.reduce(0, +) / Double(valeurs.count)
    }

    /// L'écart entre la dernière valeur et la première de la période.
    private func ecart(_ valeurs: [Double]) -> Double? {
        guard let premiere = valeurs.first, let derniere = valeurs.last, valeurs.count > 1 else { return nil }
        return derniere - premiere
    }

    private func carteVFC(_ jours: [EtatSport.JourDeForme]) -> some View {
        let valeurs = jours.compactMap(\.vfcMs)
        let derniere = jours.last?.vfcMs
        let moy = moyenne(valeurs)
        return CoquilleWidget(titre: "Variabilité cardiaque (VFC)", icone: "waveform.path.ecg",
                              couleur: Categorie.ia.couleur, droite: "\(periode) jours") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(derniere.map { String(Int($0.rounded())) } ?? "—").texte(.chiffre)
                        .foregroundStyle(Palette.textePrincipal)
                    Text("ms").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    Spacer()
                    if let derniere, let moy {
                        Puce(derniere >= moy ? "au-dessus de ta moyenne" : "en dessous de ta moyenne",
                             categorie: derniere >= moy ? .sport : .menage)
                    }
                }
                Courbe(points: jours.map { PointSerie(date: $0.jour, valeur: $0.vfcMs) },
                       couleur: Categorie.ia.couleur, hauteur: 80)
                Text("Les trous sont des nuits sans données de la montre, pas des zéros.")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire)
            }
        }
    }

    private func carteSommeil(_ jours: [EtatSport.JourDeForme]) -> some View {
        let minutes = jours.compactMap(\.sommeilMinutes)
        let moy = moyenne(minutes.map(Double.init))
        let derniers = Array(jours.suffix(periode == 7 ? 7 : periode))
        return CoquilleWidget(titre: "Sommeil", icone: "bed.double", couleur: Categorie.linge.couleur,
                              droite: moy.map { "moyenne \(EnFrancais.duree(minutes: Int($0.rounded())))" }) {
            VStack(alignment: .leading, spacing: 10) {
                Chart {
                    ForEach(Array(derniers.enumerated()), id: \.offset) { rang, jour in
                        if let valeur = jour.sommeilMinutes {
                            BarMark(x: .value("Jour", jour.jour, unit: .day), y: .value("Sommeil", Double(valeur) / 60))
                                .foregroundStyle(Categorie.linge.couleur.opacity(rang == derniers.count - 1 ? 1 : 0.6))
                                .cornerRadius(4)
                        }
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: periode == 7 ? 1 : periode == 30 ? 7 : 21)) { valeur in
                        AxisValueLabel {
                            if let date = valeur.as(Date.self) {
                                Text(periode == 7 ? String(EnFrancais.jourCourt(date).prefix(1))
                                     : date.formatted(.dateTime.day().month(.abbreviated)))
                            }
                        }
                        .foregroundStyle(Palette.texteTertiaire)
                    }
                }
                .frame(height: 110)
                if let derniere = jours.last?.sommeilMinutes {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Dernière nuit").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            Text(EnFrancais.duree(minutes: derniere)).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Régularité").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            Text(regularite(minutes)).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                        }
                    }
                }
                // 3.24 : la nuit en détail, phase par phase.
                NavigationLink { EcranNuit(jour: nil) } label: {
                    Label("Voir la dernière nuit en détail", systemImage: "chevron.right")
                        .labelStyle(.titleOnly)
                        .texte(.corpsFort)
                }
                .buttonStyle(.hal(.verre, pleineLargeur: true))
            }
        }
    }

    /// L'écart type des nuits, en mots : moins de 30 min, c'est bon.
    private func regularite(_ minutes: [Int]) -> String {
        guard minutes.count > 2, let moy = moyenne(minutes.map(Double.init)) else { return "—" }
        let variance = minutes.map { pow(Double($0) - moy, 2) }.reduce(0, +) / Double(minutes.count)
        switch variance.squareRoot() {
        case ..<30: return "bonne"
        case ..<60: return "moyenne"
        default: return "irrégulière"
        }
    }

    private func tuile(_ titre: String, _ icone: String, _ couleur: Color, _ valeur: String?,
                       _ unite: String?, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(titre, systemImage: icone).texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                .labelStyle(EtiquetteIcone(couleur: couleur))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(valeur ?? "—").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                if let unite, valeur != nil { Text(unite).texte(.legende).foregroundStyle(Palette.texteSecondaire) }
            }
            if let detail { Text(detail).texte(.legende).foregroundStyle(Categorie.sport.couleur) }
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: Rayon.controle)
    }
}

// MARK: - 3.15 La fréquence cardiaque du jour

/// 3.15 : la fréquence cardiaque de la journée, lue dans Santé sur ce
/// téléphone, avec le planning posé en face : on voit ce qui fait monter le cœur.
struct EcranFrequence: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer

    var body: some View {
        let points = foyer.frequenceDuJour
        let valeurs = points.compactMap(\.valeur)
        let moments = foyer.evenementsDuJour.filter { !$0.journeeEntiere }
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                BarrePoussee(titre: "Fréquence cardiaque") { fermer() }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let minimum = valeurs.min(), let maximum = valeurs.max() {
                            Text("\(Int(minimum)) – \(Int(maximum))").texte(.chiffre)
                                .foregroundStyle(Palette.textePrincipal)
                            Text("bpm · \(EnFrancais.jour(.now))").texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        } else {
                            Text("—").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                            Text("bpm · \(EnFrancais.jour(.now))").texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                    if valeurs.isEmpty {
                        Text("Pas encore de fréquence cardiaque aujourd'hui. Elle vient de Santé, lue sur cet iPhone : la montre la remplit au fil de la journée.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                    } else {
                        courbe(points, seances: moments.filter { $0.categorie == .sport })
                    }
                }
                .padding(Espace.interne)
                .carte()
                HStack(spacing: Espace.gouttiere) {
                    tuile("Repos", foyer.forme.fcRepos.map { "\($0) bpm" })
                    tuile("Moyenne", valeurs.isEmpty ? nil
                          : "\(Int((valeurs.reduce(0, +) / Double(valeurs.count)).rounded())) bpm")
                    tuile("VFC", foyer.forme.vfc.map { "\($0) ms" })
                }
                if !moments.isEmpty {
                    CoquilleWidget(titre: "Moments de la journée", icone: "clock", couleur: Categorie.travail.couleur) {
                        VStack(spacing: 8) {
                            ForEach(moments) { evenement in
                                HStack(spacing: 10) {
                                    Circle().fill(evenement.categorie.couleur).frame(width: 7, height: 7)
                                    Text(evenement.heure).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                        .frame(width: 46, alignment: .leading)
                                    Text(evenement.titre).texte(.corps).foregroundStyle(Palette.textePrincipal)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if let pendant = pendant(evenement, points) {
                                        Text(pendant).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                    }
                                }
                            }
                        }
                    }
                }
                Text("Le planning est posé sur la courbe. Lue dans Santé, sur ce téléphone : rien n'en part vers le serveur.")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire).surLaPhoto()
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
        .vuParHAL("Fréquence cardiaque du jour")
    }

    private func courbe(_ points: [PointSerie], seances: [Evenement]) -> some View {
        let debut = Calendar.current.startOfDay(for: .now)
        let fin = Calendar.current.date(byAdding: .day, value: 1, to: debut) ?? .now
        return VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(seances) { seance in
                    RectangleMark(xStart: .value("Début", seance.debut),
                                  xEnd: .value("Fin", seance.fin ?? seance.debut.addingTimeInterval(3600)))
                        .foregroundStyle(Categorie.alerte.voile)
                }
                ForEach(points) { point in
                    if let valeur = point.valeur {
                        AreaMark(x: .value("Heure", point.date), y: .value("bpm", valeur))
                            .foregroundStyle(LinearGradient(colors: [Categorie.alerte.couleur.opacity(0.3), .clear],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Heure", point.date), y: .value("bpm", valeur))
                            .foregroundStyle(Categorie.alerte.couleur)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartXScale(domain: debut...fin)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { valeur in
                    AxisValueLabel {
                        if let date = valeur.as(Date.self) {
                            let heure = Calendar.current.component(.hour, from: date)
                            Text(date >= fin ? "24 h" : "\(heure) h")
                        }
                    }
                    .foregroundStyle(Palette.texteTertiaire)
                }
            }
            .frame(height: 170)
            if let seance = seances.first {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Categorie.alerte.voile).frame(width: 14, height: 10)
                    Text("\(seance.titre) \(EnFrancais.heure(seance.debut))"
                         + (seance.fin.map { " – \(EnFrancais.heure($0))" } ?? ""))
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
        }
    }

    /// La FC pendant un moment : son pic pour le sport, sa moyenne sinon.
    private func pendant(_ evenement: Evenement, _ points: [PointSerie]) -> String? {
        let fin = evenement.fin ?? evenement.debut.addingTimeInterval(1800)
        let dedans = points.filter { $0.date >= evenement.debut.addingTimeInterval(-1799) && $0.date < fin }
            .compactMap(\.valeur)
        guard !dedans.isEmpty else { return nil }
        if evenement.categorie == .sport, let pic = dedans.max() { return "pic \(Int(pic)) bpm" }
        return "\(Int((dedans.reduce(0, +) / Double(dedans.count)).rounded())) bpm moyen"
    }

    private func tuile(_ titre: String, _ valeur: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            Text(valeur ?? "—").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: Rayon.controle)
    }
}

// MARK: - 3.18 Objectifs

/// 3.18 : l'objectif principal, les jours qui restent, l'avis de HAL et la
/// feuille de route par phases ; puis les objectifs secondaires (OBJ).
struct EcranObjectifs: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.dismiss) private var fermer
    @State private var objectifs: [ObjectifDetaille]?
    @State private var erreur: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                BarrePoussee(titre: "Objectifs") { fermer() }
                if let objectifs {
                    let actifs = objectifs.filter { $0.statut == "actif" }
                    if actifs.isEmpty {
                        Text("Pas encore d'objectif. HAL t'en propose un au démarrage.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    if let principal = actifs.first(where: \.principal) {
                        cartePrincipal(principal)
                    }
                    let secondaires = actifs.filter { !$0.principal }
                    if !secondaires.isEmpty {
                        EnTeteGroupe(texte: "Secondaires")
                        VStack(spacing: 0) {
                            ForEach(Array(secondaires.enumerated()), id: \.element.id) { rang, objectif in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(objectif.libelle).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                    Text(Self.precision(objectif)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Espace.interne)
                                .padding(.vertical, 12)
                                if rang < secondaires.count - 1 { Divider().overlay(Palette.verreBord) }
                            }
                        }
                        .carte(rayon: Rayon.controle)
                    }
                    let anciens = objectifs.filter { $0.statut != "actif" }
                    if !anciens.isEmpty {
                        EnTeteGroupe(texte: "Terminés ou en pause")
                        VStack(spacing: 0) {
                            ForEach(anciens) { objectif in
                                HStack {
                                    Text(objectif.libelle).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                                    Spacer()
                                    Puce(texte: Self.statut(objectif.statut))
                                }
                                .padding(.horizontal, Espace.interne)
                                .padding(.vertical, 10)
                            }
                        }
                        .carte(rayon: Rayon.controle)
                    }
                    // Un objectif se pose ou se change en parlant à HAL : il revoit le plan avec.
                    Button("Changer d'objectif avec HAL") { conversation.ouvrir() }
                        .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
        .vuParHAL("Objectifs")
        .task {
            do { objectifs = try await foyer.demander("GET", "objectifs") } catch { erreur = motif(error) }
        }
    }

    private func cartePrincipal(_ objectif: ObjectifDetaille) -> some View {
        let restant = objectif.echeance.map {
            Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: $0).day ?? 0
        }
        let couleurAvis: Categorie = objectif.avis == "irrealiste" ? .alerte
            : objectif.avis == "ambitieux" ? .menage : .sport
        return CoquilleWidget(titre: "Objectif principal", icone: "trophy", couleur: Categorie.menage.couleur,
                              droite: objectif.echeance?.formatted(.dateTime.day().month(.wide).year())) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(objectif.libelle).texte(.titre).foregroundStyle(Palette.textePrincipal)
                            .fixedSize(horizontal: false, vertical: true)
                        let precision = Self.precision(objectif)
                        if !precision.isEmpty {
                            Text(precision).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                    Spacer(minLength: 8)
                    if let restant, restant >= 0 {
                        Text("J−\(restant)").font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(Categorie.menage.couleur)
                    }
                }
                if let avis = objectif.avisDetail ?? TexteHAL.avis(objectif.avis) {
                    HStack(alignment: .top, spacing: 10) {
                        Orbe(etat: .repos, taille: 20)
                        Text(avis).texte(.corps).foregroundStyle(Palette.textePrincipal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(couleurAvis.voile, in: RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous))
                }
                if let feuille = objectif.feuilleDeRoute, !feuille.isEmpty {
                    feuilleDeRoute(feuille, depuis: objectif.dateCreation)
                }
            }
        }
    }

    /// « Semaines 1 à 4 : asseoir l'endurance. 5 à 8 : … » en phases côte à côte ;
    /// celles déjà entamées se remplissent. Un texte libre reste tel quel.
    @ViewBuilder
    private func feuilleDeRoute(_ texte: String, depuis: Date?) -> some View {
        let phases = Self.phases(texte)
        VStack(alignment: .leading, spacing: 8) {
            Text("FEUILLE DE ROUTE").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
            if phases.isEmpty {
                Text(texte).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let semaine = depuis.map {
                    (Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0) / 7 + 1
                } ?? 0
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule()
                                .fill(semaine >= phase.debut ? Categorie.menage.couleur : Palette.verreTeinteForte)
                                .frame(height: 5)
                            Text(phase.nom).texte(.legende).foregroundStyle(Palette.textePrincipal)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(phase.semaines).texte(.legende).foregroundStyle(Palette.texteTertiaire)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private struct Phase {
        let nom: String
        let semaines: String
        let debut: Int
    }

    /// Découpe une feuille de route écrite « 1 à 4 : base. 5 à 8 : volume. ».
    private static func phases(_ texte: String) -> [Phase] {
        let morceaux = texte.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lues: [Phase] = morceaux.compactMap { morceau in
            let parties = morceau.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parties.count == 2,
                  let debut = parties[0].split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) })
            else { return nil }
            let nom = parties[1].prefix(1).uppercased() + parties[1].dropFirst()
            let semaines = parties[0].lowercased().hasPrefix("sem") ? parties[0] : "sem. \(parties[0])"
            return Phase(nom: nom, semaines: semaines, debut: debut)
        }
        return lues.count == morceaux.count && lues.count > 1 ? lues : []
    }

    /// « 10 km · objectif 50 min », « pilier · force ».
    static func precision(_ objectif: ObjectifDetaille) -> String {
        var morceaux: [String] = []
        if let metres = objectif.distanceM { morceaux.append(EnFrancais.distance(metres)) }
        if let cible = objectif.cibleValeur?.valeur, let unite = objectif.cibleUnite {
            let nombre = cible.formatted(.number.precision(.fractionLength(0...1)))
            morceaux.append("objectif \(nombre) \(unite)")
        }
        if let pilier = objectif.pilier { morceaux.append("pilier · \(pilier)") }
        if !objectif.principal, let echeance = objectif.echeance {
            morceaux.append("pour le \(jourCourt(echeance))")
        }
        return morceaux.joined(separator: " · ")
    }

    static func statut(_ code: String) -> String {
        switch code {
        case "en_pause": "en pause"
        case "atteint": "atteint"
        case "abandonne": "abandonné"
        default: code
        }
    }
}

// MARK: - 3.17 Progression

/// La progression : un exercice par ligne, son record et sa courbe. Toucher
/// ouvre son détail [3.17].
struct EcranProgression: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var semaines: [SemaineDExercice]?
    @State private var erreur: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                BarrePoussee(titre: "Progression") { fermer() }
                if let semaines {
                    let codes = Self.exercices(semaines)
                    if codes.isEmpty {
                        Text("Rien encore : les séries saisies en séance apparaîtront ici, semaine par semaine.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(codes.enumerated()), id: \.element.0) { rang, exercice in
                            let siennes = semaines.filter { $0.code == exercice.0 }
                            NavigationLink { EcranExercice(code: exercice.0, libelle: exercice.1) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(Self.nomCourt(exercice.1)).texte(.corpsFort)
                                            .foregroundStyle(Palette.textePrincipal).lineLimit(1)
                                        Text(siennes.last.map(Self.meilleure) ?? "—")
                                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                    }
                                    Spacer(minLength: 8)
                                    Courbe(points: siennes.map { PointSerie(date: $0.lundi, valeur: $0.meilleureCharge ?? $0.meilleuresRepetitions.map(Double.init)) },
                                           couleur: Categorie.sport.couleur, hauteur: 30)
                                        .frame(width: 90)
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Palette.texteTertiaire)
                                }
                                .padding(.horizontal, Espace.interne)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if rang < codes.count - 1 { Divider().overlay(Palette.verreBord) }
                        }
                    }
                    .carte(rayon: Rayon.controle)
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
        .vuParHAL("Progression")
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

    /// « 62,5 kg × 6 », ou « 12 reps » sans charge.
    static func meilleure(_ semaine: SemaineDExercice) -> String {
        if let charge = semaine.meilleureCharge, charge > 0 {
            return "\(Poids.texte(charge)) × \(semaine.meilleuresRepetitions ?? 0)"
        }
        return "\(semaine.meilleuresRepetitions ?? 0) reps"
    }

    /// « Développé couché » plutôt que « Développé couché barre, prise moyenne ».
    static func nomCourt(_ libelle: String) -> String {
        String(libelle.split(separator: ",").first ?? Substring(libelle))
    }
}

/// 3.17 : un exercice. La meilleure série et sa courbe sur douze semaines, les
/// séances semaine par semaine, et ce qui peut le remplacer (EXO-2).
struct EcranExercice: View {
    let code: String
    let libelle: String
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var semaines: [SemaineDExercice] = []
    @State private var remplacements: [ExerciceCatalogue] = []
    @State private var charge = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                BarrePoussee(titre: EcranProgression.nomCourt(libelle)) { fermer() }
                if let derniere = semaines.last {
                    meilleureSerie(derniere)
                    seances
                    if !remplacements.isEmpty { carteRemplacements }
                } else if charge {
                    Text("Pas encore de série sur cet exercice.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
        .vuParHAL("Progression · \(EcranProgression.nomCourt(libelle))")
        .task { await charger() }
    }

    private func meilleureSerie(_ derniere: SemaineDExercice) -> some View {
        let premiere = semaines.first
        let ecart: String? = {
            guard let premiere, premiere.lundi != derniere.lundi,
                  let avant = premiere.meilleureCharge, let apres = derniere.meilleureCharge, apres != avant
            else { return nil }
            let nombre = max(1, Calendar.current.dateComponents([.weekOfYear], from: premiere.lundi, to: derniere.lundi).weekOfYear ?? 1)
            return "\(apres > avant ? "+" : "−")\(Poids.texte(abs(apres - avant))) en \(nombre) sem."
        }()
        return CoquilleWidget(titre: "Meilleure série", icone: "trophy", couleur: Categorie.menage.couleur,
                              droite: derniere.lundi.formatted(.dateTime.day().month(.abbreviated))) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let charge = derniere.meilleureCharge, charge > 0 {
                        Text(charge.formatted(.number.precision(.fractionLength(0...1)))).texte(.chiffre)
                            .foregroundStyle(Palette.textePrincipal)
                        Text("kg × \(derniere.meilleuresRepetitions ?? 0)").texte(.corps)
                            .foregroundStyle(Palette.texteSecondaire)
                    } else {
                        Text("\(derniere.meilleuresRepetitions ?? 0)").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                        Text("répétitions").texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    Spacer()
                    if let ecart { Puce(ecart, categorie: .sport) }
                }
                Chart {
                    ForEach(semaines, id: \.lundi) { semaine in
                        if let valeur = semaine.meilleureCharge ?? semaine.meilleuresRepetitions.map(Double.init) {
                            AreaMark(x: .value("Semaine", semaine.lundi), y: .value("Valeur", valeur))
                                .foregroundStyle(LinearGradient(colors: [Categorie.sport.couleur.opacity(0.35), .clear],
                                                                startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Semaine", semaine.lundi), y: .value("Valeur", valeur))
                                .foregroundStyle(Categorie.sport.couleur)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Palette.texteTertiaire)
                    }
                }
                .frame(height: 110)
            }
        }
    }

    /// Une ligne par semaine : « 4 × 6 · 62,5 kg ».
    private var seances: some View {
        CoquilleWidget(titre: "Séances", icone: "clock", couleur: Categorie.travail.couleur) {
            VStack(spacing: 0) {
                ForEach(Array(semaines.reversed().enumerated()), id: \.offset) { rang, semaine in
                    HStack {
                        Text(semaine.lundi.formatted(.dateTime.day().month(.abbreviated)))
                            .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                            .frame(width: 70, alignment: .leading)
                        Text([semaine.series.map { "\($0) × \(semaine.meilleuresRepetitions ?? 0)" },
                              semaine.meilleureCharge.flatMap { $0 > 0 ? Poids.texte($0) : nil }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        if let volume = semaine.volume, volume > 0 {
                            Text("\(EnFrancais.nombre(Int(volume.rounded()))) kg")
                                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                    .padding(.vertical, 8)
                    if rang < semaines.count - 1 { Divider().overlay(Palette.verreBord) }
                }
            }
        }
    }

    private var carteRemplacements: some View {
        CoquilleWidget(titre: "Remplacements possibles", icone: "arrow.left.arrow.right",
                       couleur: Categorie.ia.couleur) {
            Flux(espacement: 6) {
                ForEach(remplacements.prefix(8)) { exercice in
                    Text(EcranProgression.nomCourt(exercice.libelle))
                        .texte(.legende).foregroundStyle(Palette.textePrincipal)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Palette.verreTeinte, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.verreBord, lineWidth: 0.5))
                }
            }
        }
    }

    private func charger() async {
        semaines = (try? await foyer.demander("GET", "appli/progression?exercice=\(code)")) ?? []
        charge = true
        // Les autres exercices du même groupe, sauf ceux qu'une limitation interdit.
        let catalogue: [ExerciceCatalogue] = (try? await foyer.demander("GET", "exercices?discipline=musculation")) ?? []
        if let groupe = catalogue.first(where: { $0.code == code })?.groupePrincipal {
            remplacements = catalogue.filter { $0.groupePrincipal == groupe && $0.code != code && $0.interdit != true }
        }
    }
}

/// Le haut d'un écran poussé sur la photo : retour et titre (C.4, Barre de titre).
struct BarrePoussee: View {
    let titre: String
    var retour: () -> Void

    var body: some View {
        ZStack {
            Text(titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                .padding(.horizontal, 48).surLaPhoto()
            HStack {
                BoutonRond("chevron.left", libelle: "Retour", action: retour)
                Spacer()
            }
        }
        .frame(height: 44)
    }
}

// MARK: - 3.11 Annoncer une séance libre

/// LIB-3, LIB-4 : une séance qu'on fera à sa façon. HAL dit tout de suite ce
/// qu'il conseille d'éviter ce jour-là, et ajuste la suite.
struct FormulaireAnnonce: View {
    @Environment(Foyer.self) private var foyer
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer
    @State private var maintenant = false
    @State private var discipline = "musculation"
    @State private var debut = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0,
                                                     of: .now.addingTimeInterval(86_400)) ?? .now
    @State private var duree: Double = 60
    @State private var texte = ""
    @State private var envoi = false
    @State private var reponse: String?
    @State private var erreur: String?

    /// Ce que le serveur accepte pour une séance (musculation, course, cardio).
    private static let disciplines = [("musculation", "Musculation"), ("course", "Course"), ("cardio", "Cardio")]

    /// 3.11 : « Annoncer » une séance à venir, ou la commencer « Maintenant »
    /// (la séance libre de 3.10). HAL répond tout de suite à une annonce (LIB-4).
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                Segmente(choix: [(false, "Annoncer"), (true, "Maintenant")], selection: $maintenant)
                EnTeteGroupe(texte: "Discipline")
                HStack(spacing: 8) {
                    ForEach(Self.disciplines, id: \.0) { choix in
                        PuceChoix(texte: choix.1, choisie: discipline == choix.0) { discipline = choix.0 }
                    }
                }
                if maintenant {
                    Text(discipline == "musculation"
                         ? "La séance s'ouvre tout de suite : tu ajoutes tes exercices au fil de l'eau, sans réseau s'il le faut."
                         : "Une course ou du cardio se lance sur la montre : elle arrivera par Santé et comptera toute seule.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Jour").texte(.corps).foregroundStyle(Palette.textePrincipal)
                            Spacer()
                            DatePicker("Jour", selection: $debut, in: Date.now..., displayedComponents: .date)
                                .labelsHidden()
                        }
                        .padding(.vertical, 8)
                        Divider().overlay(Palette.verreBord)
                        HStack {
                            Text("Heure").texte(.corps).foregroundStyle(Palette.textePrincipal)
                            Spacer()
                            DatePicker("Heure", selection: $debut, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        .padding(.vertical, 8)
                        Divider().overlay(Palette.verreBord)
                        HStack {
                            Text("Durée").texte(.corps).foregroundStyle(Palette.textePrincipal)
                            Spacer()
                            Compteur(titre: "min", valeur: $duree, pas: 15, bornes: 15...240, compact: true)
                                .frame(width: 200)
                        }
                        .padding(.vertical, 6)
                    }
                    .padding(.horizontal, Espace.interne)
                    .carte(rayon: Rayon.controle)
                    EnTeteGroupe(texte: "Ce que je vais faire (si tu sais)")
                    TextField("Jambes et épaules, ou un footing tranquille…", text: $texte, axis: .vertical)
                        .texte(.corps).foregroundStyle(Palette.textePrincipal)
                        .lineLimit(2...4)
                        .padding(Espace.interne)
                        .carte(rayon: Rayon.controle)
                    HStack(alignment: .top, spacing: 10) {
                        Orbe(etat: .repos, taille: 22)
                        Text(reponse ?? "HAL répond tout de suite : ce qu'il conseille d'éviter ce jour-là, puis il ajuste la suite de ta semaine.")
                            .texte(.corps).foregroundStyle(Palette.textePrincipal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Espace.interne)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: Rayon.controle)
                }
                if let erreur {
                    Label(erreur, systemImage: "exclamationmark.circle")
                        .texte(.corps).foregroundStyle(Categorie.alerte.couleur)
                }
                if maintenant {
                    Button(discipline == "musculation" ? "Commencer la séance" : "Fermer") {
                        guard discipline == "musculation" else { fermer(); return }
                        (fermerFeuille?.fermer ?? { fermer() })()
                        seance.lancerLibre(file: file)
                    }
                    .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                } else if reponse == nil {
                    Button { Task { await envoyer() } } label: {
                        HStack {
                            if envoi { ProgressView() }
                            Text("Annoncer la séance")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                    .disabled(envoi)
                } else {
                    Button("Fermer") { (fermerFeuille?.fermer ?? { fermer() })() }
                        .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
                }
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Séance libre")
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
                corps: ClientAPI.corps(Demande(discipline: discipline, debut: debut, dureeMinutes: Int(duree),
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

    /// 3.20 : qui propose, la séance dans sa carte, « Je viens » ou « Pas cette fois ».
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Avatar(nom: invitation.qui, couleur: Categorie.travail.couleur, taille: 30)
                Text("\(invitation.qui) te propose une séance").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            }
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(Categorie.sport.couleur, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(invitation.lieu ?? "Sport") · \(EnFrancais.jour(invitation.debut)) · \(EnFrancais.heure(invitation.debut))")
                        .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                        .lineLimit(2)
                    Text("tu es libre à cette heure-là").texte(.legende).foregroundStyle(Categorie.sport.couleur)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous))
            HStack {
                Button("Je viens") { repondre(true) }.buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                Button("Pas cette fois") { repondre(false) }.buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
            }
            .disabled(envoi)
            Text("Accepter crée ta propre séance, avec tes règles. Refuser ne défait rien chez \(invitation.qui).")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                .fixedSize(horizontal: false, vertical: true)
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
