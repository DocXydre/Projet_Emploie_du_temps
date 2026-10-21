import Charts
import SwiftUI

// 3.24 Nuit en détail et 3.25 Forme et corps. Tout vient de
// `GET /appli/sante/nuit` et `GET /appli/sante/forme`, calculé en base (SAN-15, SAN-16).

private let francais = Locale(identifier: "fr_FR")

/// L'en-tête des écrans poussés de Santé : retour, titre, et ce qu'on veut à droite.
private struct EnTeteSante<Droite: View>: View {
    let titre: String
    @ViewBuilder var droite: Droite
    @Environment(\.dismiss) private var fermer

    var body: some View {
        ZStack {
            Text(titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal).surLaPhoto()
            HStack {
                BoutonRond("chevron.left", libelle: "Retour") { fermer() }
                Spacer()
                droite
            }
        }
        .frame(height: 44)
    }
}

private func tuile(_ titre: String, _ valeur: String?, _ detail: String?, couleur: Color = Palette.textePrincipal) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
        Text(valeur ?? "—").texte(.titreWidget).foregroundStyle(valeur == nil ? Palette.texteTertiaire : couleur)
            .lineLimit(1).minimumScaleFactor(0.7)
        Text(detail ?? " ").texte(.legende).foregroundStyle(Palette.texteTertiaire).lineLimit(1)
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.verreTeinteForte, in: RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous))
}

private func nombre(_ valeur: Double, _ decimales: Int = 1) -> String {
    valeur.formatted(.number.precision(.fractionLength(0...decimales)).locale(francais))
}

// MARK: - 3.24 Nuit en détail

/// Les phases, dans l'ordre de l'hypnogramme, avec leur couleur.
enum PhaseSommeil: String, CaseIterable {
    case eveille, paradoxal, leger, profond

    var libelle: String {
        switch self {
        case .eveille: "Éveillé"
        case .paradoxal: "Paradoxal"
        case .leger: "Léger"
        case .profond: "Profond"
        }
    }

    var couleur: Color {
        switch self {
        case .eveille: Categorie.cours.couleur
        case .paradoxal: Categorie.travail.couleur
        case .leger: Categorie.ia.couleur
        case .profond: Categorie.linge.couleur
        }
    }
}

/// 3.24 : une nuit, en touchant une nuit de 3.16. Les flèches passent d'une
/// nuit à l'autre.
struct EcranNuit: View {
    @State var jour: Date?
    @Environment(Foyer.self) private var foyer
    @State private var nuit: NuitDetaillee?
    @State private var erreur: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                EnTeteSante(titre: "Sommeil") {
                    if let nuit {
                        HStack(spacing: 8) {
                            BoutonRond("chevron.backward", libelle: "Nuit d'avant") { changer(nuit.jour, de: -1) }
                            BoutonRond("chevron.forward", libelle: "Nuit d'après") { changer(nuit.jour, de: 1) }
                                .disabled(Calendar.current.isDateInToday(nuit.jour))
                        }
                    }
                }
                if let nuit {
                    resume(nuit)
                    hypnogramme(nuit)
                    durees(nuit)
                    corps(nuit)
                    Text(nuit.deLaMontre
                         ? "Apple Watch, reçu par Santé. Les phases viennent de la montre ; une nuit sans montre n'a pas de phases, seulement sa durée."
                         : "Nuit enregistrée sans la montre : Santé ne donne que le temps endormi.")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire).surLaPhoto()
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        .padding(Espace.interne).frame(maxWidth: .infinity, alignment: .leading)
                        .carte(rayon: Rayon.controle)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
        .vuParHAL("Sommeil · une nuit")
        .task(id: jour) { await charger() }
    }

    private func changer(_ jour: Date, de jours: Int) {
        self.jour = Calendar.current.date(byAdding: .day, value: jours, to: jour)
    }

    private func charger() async {
        let chemin = jour.map { "appli/sante/nuit?jour=\(Dates.jourISO($0))" } ?? "appli/sante/nuit"
        do {
            nuit = try await foyer.demander("GET", chemin)
            erreur = nil
        } catch {
            nuit = nil
            erreur = "Pas de phases de sommeil pour cette nuit. Avec la montre au poignet, elles arrivent par Santé."
        }
    }

    private func resume(_ nuit: NuitDetaillee) -> some View {
        let dormi = (nuit.minutes ?? [:]).filter { $0.key != "eveille" }.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Nuit du \(EnFrancais.jour(nuit.jour.addingTimeInterval(-86_400))) au \(EnFrancais.jour(nuit.jour))")
                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(EnFrancais.duree(minutes: dormi)).texte(.chiffre).foregroundStyle(Categorie.ia.couleur)
                    Text("de sommeil · \(EnFrancais.duree(minutes: nuit.minutes?["eveille"] ?? 0)) éveillé")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Couché \(EnFrancais.heure(nuit.coucher))").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Text("Levé \(EnFrancais.heure(nuit.lever))").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                }
            }
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: Rayon.controle)
    }

    private func hypnogramme(_ nuit: NuitDetaillee) -> some View {
        CoquilleWidget(titre: "Les phases de la nuit", icone: "bed.double", couleur: Categorie.ia.couleur) {
            Chart {
                ForEach(nuit.phases.indices, id: \.self) { i in
                    let phase = nuit.phases[i]
                    if let p = PhaseSommeil(rawValue: phase.phase) {
                        RectangleMark(xStart: .value("Début", phase.debut), xEnd: .value("Fin", phase.fin),
                                      y: .value("Phase", p.libelle), height: .ratio(0.6))
                            .foregroundStyle(p.couleur)
                            .cornerRadius(4)
                    }
                }
            }
            .chartYScale(domain: PhaseSommeil.allCases.map(\.libelle))
            .chartXScale(domain: nuit.coucher...nuit.lever)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel().foregroundStyle(Palette.texteSecondaire)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { valeur in
                    AxisGridLine().foregroundStyle(Palette.verreSeparateur)
                    AxisValueLabel { if let date = valeur.as(Date.self) { Text(EnFrancais.heure(date)) } }
                        .foregroundStyle(Palette.texteTertiaire)
                }
            }
            .frame(height: 150)
        }
    }

    private func durees(_ nuit: NuitDetaillee) -> some View {
        CoquilleWidget(titre: "Combien de chaque", icone: "moon", couleur: Categorie.ia.couleur,
                       droite: nuit.habitude == nil ? nil : "habitude sur 30 nuits") {
            VStack(spacing: 10) {
                ForEach([PhaseSommeil.profond, .paradoxal, .leger, .eveille], id: \.self) { phase in
                    let minutes = nuit.minutes?[phase.rawValue]
                    let habitude = nuit.habitude?[phase.rawValue]
                    // Moins de profond ou de paradoxal que d'habitude, de plus d'un quart d'heure : en ambre.
                    let moins = (phase == .profond || phase == .paradoxal)
                        && (minutes ?? 0) + 15 < (habitude ?? 0)
                    HStack(spacing: 10) {
                        Circle().fill(phase.couleur).frame(width: 10, height: 10)
                        Text(phase.libelle).texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        if let habitude {
                            Text("habituel \(EnFrancais.duree(minutes: habitude))").texte(.legende)
                                .foregroundStyle(Palette.texteTertiaire)
                        }
                        Text(minutes.map { EnFrancais.duree(minutes: $0) } ?? "—").texte(.corpsFort)
                            .foregroundStyle(moins ? Categorie.menage.couleur : Palette.textePrincipal)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func corps(_ nuit: NuitDetaillee) -> some View {
        let m = nuit.mesures
        return CoquilleWidget(titre: "Le corps la nuit", icone: "heart", couleur: Categorie.alerte.couleur) {
            VStack(alignment: .leading, spacing: 10) {
                if let frequence = nuit.frequence, frequence.count > 1 {
                    Chart {
                        ForEach(frequence.indices, id: \.self) { i in
                            if let bpm = frequence[i].bpm {
                                LineMark(x: .value("Minute", frequence[i].minute), y: .value("bpm", bpm))
                                    .foregroundStyle(Categorie.alerte.couleur)
                                    .interpolationMethod(.catmullRom)
                            }
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis(.hidden)
                    .chartXAxis(.hidden)
                    .frame(height: 70)
                    if let bas = nuit.fcPlusBasse {
                        Text("FC la nuit : \(bas.bpm) au plus bas, vers \(EnFrancais.heure(bas.quand))")
                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    tuile("Respiration", m?.respiration?.valeur.map { "\(nombre($0)) /min" },
                          m?.respiration?.habitude.map { "habituel \(nombre($0))" })
                    tuile("SpO2", m?.spo2?.valeur.map { "\(nombre($0, 0)) %" },
                          m?.spo2?.plusBas.map { "au plus bas \(nombre($0, 0)) %" })
                    tuile("Température poignet", ecartTemperature(m?.temperaturePoignet), "vs ton habitude")
                    let vfcBasse = (m?.vfc?.valeur ?? 0) < (m?.vfc?.habitude ?? 0) * 0.85
                    tuile("VFC de la nuit", m?.vfc?.valeur.map { "\(nombre($0, 0)) ms" },
                          m?.vfc?.habitude.map { "habituelle \(nombre($0, 0)) ms" },
                          couleur: vfcBasse ? Categorie.menage.couleur : Palette.textePrincipal)
                }
            }
        }
    }

    /// La montre ne donne la température qu'en écart à l'habitude qui a du sens.
    private func ecartTemperature(_ valeur: NuitDetaillee.Valeur?) -> String? {
        guard let v = valeur?.valeur, let h = valeur?.habitude else { return nil }
        let ecart = v - h
        return "\(ecart >= 0 ? "+" : "−")\(nombre(abs(ecart))) °C"
    }
}

// MARK: - 3.25 Forme et corps

/// 3.25 : la forme sur 30 jours, 90 jours, un an ou tout l'historique.
struct EcranForme: View {
    @Environment(Foyer.self) private var foyer
    @State private var periode = 90
    @State private var forme: FormeSante?
    @State private var erreur: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                EnTeteSante(titre: "Forme et corps") { EmptyView() }
                Segmente(choix: [(30, "30 j"), (90, "90 j"), (365, "1 an"), (0, "Tout")], selection: $periode)
                if let forme {
                    // MON-8 : la VO2max et la FC de récupération ne viennent que de la montre.
                    if foyer.aUneMontre {
                        vo2max(forme.vo2max)
                        recuperation(forme.fcRecuperation)
                    }
                    poids(forme.poids)
                    quotidien(forme)
                    Text("Ce qui vient de Santé, toutes sources : Apple Watch, iPhone et la balance. Une même donnée venue de deux sources n'est comptée qu'une fois, la montre d'abord.")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire).surLaPhoto()
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
        .vuParHAL("Forme et corps")
        .task(id: periode) {
            do {
                forme = try await foyer.demander("GET", "appli/sante/forme?jours=\(periode)")
            } catch {
                erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
            }
        }
    }

    private func tendance(_ premiere: Double?, _ derniere: Double?, _ unite: String) -> String? {
        guard let premiere, let derniere else { return nil }
        let ecart = derniere - premiere
        let periode = self.periode == 0 ? "" : " en \(self.periode == 365 ? "1 an" : "\(self.periode) j")"
        return "\(ecart >= 0 ? "+" : "−")\(nombre(abs(ecart)))\(unite)\(periode)"
    }

    private func entete(_ valeur: String?, _ unite: String, _ couleur: Color, _ droite: String?, _ couleurDroite: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(valeur ?? "—").texte(.chiffre).foregroundStyle(valeur == nil ? Palette.texteTertiaire : couleur)
            Text(unite).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            Spacer()
            if let droite { Text(droite).texte(.corpsFort).foregroundStyle(couleurDroite) }
        }
    }

    private func vo2max(_ points: [FormeSante.Point]) -> some View {
        CoquilleWidget(titre: "VO2max", icone: "flame", couleur: Categorie.sport.couleur, droite: "estimée par la montre") {
            VStack(alignment: .leading, spacing: 8) {
                entete(points.last.map { nombre($0.valeur) }, "ml/kg/min", Categorie.sport.couleur,
                       tendance(points.first?.valeur, points.last?.valeur, ""), Categorie.sport.couleur)
                if points.count > 1 {
                    Chart(points.indices, id: \.self) { i in
                        LineMark(x: .value("Jour", points[i].jour), y: .value("VO2max", points[i].valeur))
                            .foregroundStyle(Categorie.sport.couleur)
                        PointMark(x: .value("Jour", points[i].jour), y: .value("VO2max", points[i].valeur))
                            .foregroundStyle(Categorie.sport.couleur).symbolSize(20)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis(.hidden)
                    .chartXAxis { axeDates }
                    .frame(height: 90)
                } else {
                    Text("Il faut quelques courses dehors avec la montre pour qu'elle l'estime.")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                }
            }
        }
    }

    private var axeDates: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { valeur in
            AxisValueLabel {
                if let date = valeur.as(Date.self) {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).locale(francais)))
                }
            }
            .foregroundStyle(Palette.texteTertiaire)
        }
    }

    private func recuperation(_ points: [FormeSante.Recuperation]) -> some View {
        let habitude = points.isEmpty ? nil : points.map(\.valeur).reduce(0, +) / Double(points.count)
        return CoquilleWidget(titre: "FC de récupération", icone: "heart", couleur: Categorie.alerte.couleur,
                              droite: "une minute après l'arrêt") {
            VStack(alignment: .leading, spacing: 8) {
                entete(points.last.map { "−\(Int($0.valeur))" }, "bpm en 1 min", Categorie.alerte.couleur,
                       habitude.map { "habituel −\(Int($0.rounded()))" }, Palette.texteSecondaire)
                if !points.isEmpty {
                    Chart(points.indices, id: \.self) { i in
                        BarMark(x: .value("Séance", i), y: .value("bpm", points[i].valeur))
                            .foregroundStyle(Categorie.alerte.couleur.opacity(i == points.count - 1 ? 1 : 0.55))
                            .cornerRadius(4)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis(.hidden)
                    .chartXAxis(.hidden)
                    .frame(height: 70)
                }
                Text("Une barre par séance de course. Plus la FC redescend vite, mieux tu récupères.")
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func poids(_ pesees: [FormeSante.Pesee]) -> some View {
        let source = pesees.last?.source.map { $0 == "saisie" ? "saisi dans l'appli" : "\($0), via Santé" }
        return CoquilleWidget(titre: "Poids", icone: "scalemass", couleur: Categorie.linge.couleur, droite: source) {
            VStack(alignment: .leading, spacing: 8) {
                entete(pesees.last.map { nombre($0.valeur) }, "kg", Categorie.linge.couleur,
                       tendance(pesees.first?.valeur, pesees.last?.valeur, " kg"), Palette.texteSecondaire)
                if pesees.count > 1 {
                    Chart(pesees.indices, id: \.self) { i in
                        LineMark(x: .value("Jour", pesees[i].jour), y: .value("kg", pesees[i].valeur))
                            .foregroundStyle(Categorie.linge.couleur)
                            .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis(.hidden)
                    .chartXAxis { axeDates }
                    .frame(height: 70)
                }
            }
        }
    }

    private func quotidien(_ forme: FormeSante) -> some View {
        let m = forme.moyennes
        let fcRepos = forme.tendances?.fcRepos.map { "\($0 > 0 ? "+" : $0 < 0 ? "−" : "")\(Int(abs($0))) sur la période" }
        return CoquilleWidget(titre: "Au quotidien", icone: "bolt", couleur: Categorie.menage.couleur,
                              droite: periode == 0 ? "moyennes" : "moyennes sur \(periode == 365 ? "1 an" : "\(periode) j")") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                tuile("Énergie active", m?.energieJour.map { "\(Int($0)) kcal" }, "par jour")
                tuile("FC au repos", m?.fcRepos.map { "\(Int($0)) bpm" }, fcRepos)
                tuile("SpO2 la nuit", m?.spo2.map { "\(nombre($0, 0)) %" },
                      m?.spo2PlusBas.map { "au plus bas \(nombre($0, 0)) %" })
                tuile("Respiration", m?.respiration.map { "\(nombre($0)) /min" }, "la nuit")
            }
        }
    }
}
