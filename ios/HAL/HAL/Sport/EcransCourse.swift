import Charts
import MapKit
import SwiftUI

// 3.22 et 3.23 : une course faite, avec ses étapes et sa carte. Tout vient de
// `GET /appli/seances/{id}/course`, calculé en base dans les séries brutes de
// la montre (SAN-11 à SAN-14).

/// Dans la séance prévue (3.3) : le détail quand le serveur l'a, sinon le
/// résumé de la montre (3.14).
struct CourseDeLaMontre: View {
    let idOccurrence: Int
    let montre: DetailSeance.Montre
    let discipline: String?
    @Environment(Foyer.self) private var foyer
    @State private var detail: CourseDetaillee?
    @State private var lu = false

    var body: some View {
        Group {
            if let detail, detail.detaillee {
                DetailCourse(course: detail)
            } else if lu {
                CourseFaite(montre: montre, discipline: discipline)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: idOccurrence) {
            detail = try? await foyer.demander("GET", "appli/seances/\(idOccurrence)/course")
            lu = true
        }
    }
}

/// 3.22 : le résumé, la carte, les étapes face au prévu, l'allure et la FC
/// étape par étape, les zones, la dynamique de course.
struct DetailCourse: View {
    let course: CourseDetaillee
    @State private var enGrand = false

    var body: some View {
        VStack(spacing: Espace.gouttiere) {
            resume
            if course.trace.count > 1, let id = course.idActivite { CarteMeteoCourse(idActivite: id) }
            if course.trace.count > 1 { carteDuParcours }
            if course.etapes.count > 1 { etapes }
            if course.courbe.count > 1 { allureEtFC }
            if let zones = course.zones, zones.count == 5, zones.reduce(0, +) > 0 { zonesCardiaques(zones) }
            if !tuilesDynamique.isEmpty { dynamique }
        }
        .fullScreenCover(isPresented: $enGrand) {
            EcranParcours(course: course).background { Fond() }
        }
    }

    // MARK: Le résumé

    private var titre: String {
        let fractions = course.fractions
        guard fractions.count >= 2 else { return course.etapes.count > 1 ? "Course en étapes" : "Course" }
        let distances = fractions.compactMap(\.distanceM)
        if distances.count == fractions.count {
            let moyenne = distances.reduce(0, +) / Double(distances.count)
            return "Fractionné \(fractions.count) × \(Int((moyenne / 100).rounded()) * 100) m"
        }
        return "Fractionné, \(fractions.count) fractions"
    }

    private var resume: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(titre) · fait").texte(.titre).foregroundStyle(Palette.textePrincipal)
                    Text(sousTitre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                Spacer()
                Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Categorie.sport.couleur)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    chiffre("Distance", course.distanceM.map(EnFrancais.distance), Categorie.sport.couleur)
                    chiffre("Durée", course.dureeSecondes.map(EnFrancais.chrono))
                }
                GridRow {
                    chiffre("Allure moyenne", course.allureSKm.map { "\(EnFrancais.chrono($0)) /km" })
                    chiffre("FC moyenne", course.fcMoyenne.map { "\($0) bpm" }, Categorie.alerte.couleur)
                }
            }
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: Rayon.controle)
    }

    private var sousTitre: String {
        let debut = course.debut
        let fin = debut.addingTimeInterval(TimeInterval(course.dureeSecondes ?? 0))
        return "\(EnFrancais.jour(debut)) · \(EnFrancais.heure(debut)) – \(EnFrancais.heure(fin))"
    }

    private func chiffre(_ titre: String, _ valeur: String?, _ couleur: Color = Palette.textePrincipal) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            Text(valeur ?? "—").texte(.titre).foregroundStyle(valeur == nil ? Palette.texteTertiaire : couleur)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: La carte

    private var carteDuParcours: some View {
        CoquilleWidget(titre: "Le parcours", icone: "mappin", couleur: Categorie.sport.couleur,
                       droite: course.deniveleM.map { "D+ \($0) m" }) {
            VStack(alignment: .leading, spacing: 10) {
                CarteParcours(course: course, coloration: .etapes, choisi: nil)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .allowsHitTesting(false)
                HStack(spacing: 14) {
                    legende("Footing", Categorie.sport.couleur)
                    if !course.fractions.isEmpty { legende("Fractions", Categorie.alerte.couleur) }
                    Spacer()
                    // La séance s'ouvre dans une feuille : la carte en grand la recouvre.
                    Button("Voir en grand") { enGrand = true }
                        .buttonStyle(.hal(.verre))
                }
            }
        }
    }

    private func legende(_ texte: String, _ couleur: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(couleur).frame(width: 14, height: 4)
            Text(texte).texte(.legende).foregroundStyle(Palette.texteSecondaire)
        }
    }

    // MARK: Les étapes

    /// L'échauffement, les fractions en un bloc, le retour au calme. Les
    /// récupérations entre deux fractions se résument sous le bloc.
    private var etapes: some View {
        let fractions = course.fractions
        let premiere = fractions.first?.rang ?? .max
        let derniere = fractions.last?.rang ?? .min
        return CoquilleWidget(titre: "Étapes · prévu et fait", icone: "timer", couleur: Categorie.travail.couleur,
                              droite: "\(course.etapes.count) étapes") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(course.etapes) { etape in
                    if fractions.count >= 2, etape.rang == premiere {
                        blocFractions(fractions)
                    } else if fractions.count >= 2, etape.rang > premiere, etape.rang <= derniere {
                        EmptyView()
                    } else {
                        ligneEtape(etape)
                    }
                }
            }
        }
    }

    private func ligneEtape(_ etape: CourseDetaillee.Etape) -> some View {
        let rate = rate(etape)
        return HStack(spacing: 10) {
            Capsule().fill(etape.rapide ? Categorie.alerte.couleur : Categorie.sport.couleur).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(etape.nom).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                if let prevu = prevu(etape.prevu) {
                    Text("prévu : \(prevu)").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text([EnFrancais.chrono(etape.dureeS), etape.allureSKm.map { "\(EnFrancais.chrono($0)) /km" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .texte(.corpsFort).foregroundStyle(rate ? Categorie.menage.couleur : Palette.textePrincipal)
                    .monospacedDigit()
                if let fc = etape.fc {
                    Text("FC \(fc)").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
            if etape.prevu != nil {
                Image(systemName: rate ? "exclamationmark.circle" : "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(rate ? Categorie.menage.couleur : Categorie.sport.couleur)
            }
        }
    }

    /// Une étape est ratée quand elle dépasse l'objectif de plus de trois secondes.
    private func rate(_ etape: CourseDetaillee.Etape) -> Bool {
        guard let objectif = etape.prevu?.objectifS else { return false }
        return etape.dureeS > objectif + 3
    }

    private func prevu(_ prevu: CourseDetaillee.Prevu?) -> String? {
        guard let prevu else { return nil }
        var morceaux: [String] = []
        if let distance = prevu.distanceM, let objectif = prevu.objectifS {
            morceaux.append("\(distance) m en \(EnFrancais.chrono(objectif))")
        } else if let distance = prevu.distanceM {
            morceaux.append("\(distance) m")
        } else if let duree = prevu.dureeS {
            morceaux.append(EnFrancais.duree(minutes: duree / 60))
        }
        if let zone = prevu.zone { morceaux.append("en zone \(zone)") }
        if let allure = prevu.allure { morceaux.append(allure == "trot" ? "en trottinant" : allure) }
        return morceaux.isEmpty ? nil : morceaux.joined(separator: " ")
    }

    private func blocFractions(_ fractions: [CourseDetaillee.Etape]) -> some View {
        let objectif = fractions.first?.prevu?.objectifS
        let plusLongue = Double(fractions.map(\.dureeS).max() ?? 1)
        let plusCourte = Double(fractions.map(\.dureeS).min() ?? 1)
        let recups = course.etapes.filter { !$0.rapide && $0.rang > fractions.first!.rang && $0.rang < fractions.last!.rang }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Capsule().fill(Categorie.alerte.couleur).frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(titre.replacingOccurrences(of: "Fractionné ", with: "")).texte(.corpsFort)
                        .foregroundStyle(Palette.textePrincipal)
                    if let prevu = prevu(fractions.first?.prevu) {
                        Text("prévu : \(prevu) chacune").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(fractions.enumerated()), id: \.offset) { rang, fraction in
                    let rate = rate(fraction)
                    VStack(spacing: 4) {
                        Text(EnFrancais.chrono(fraction.dureeS)).texte(.etiquette)
                            .foregroundStyle(rate ? Categorie.menage.couleur : Palette.textePrincipal)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(rate ? Categorie.menage.couleur : Categorie.alerte.couleur.opacity(0.9))
                            .frame(height: plusLongue > plusCourte
                                   ? 14 + 30 * (Double(fraction.dureeS) - plusCourte) / (plusLongue - plusCourte) : 24)
                        Text("F\(rang + 1)").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, 14)
            if let resume = resumeRecup(recups, objectif: objectif) {
                Text(resume).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resumeRecup(_ recups: [CourseDetaillee.Etape], objectif: Int?) -> String? {
        var morceaux: [String] = []
        if let objectif { morceaux.append("Objectif \(EnFrancais.chrono(objectif))") }
        if !recups.isEmpty {
            let duree = recups.map(\.dureeS).reduce(0, +) / recups.count
            morceaux.append("récup moyenne \(EnFrancais.chrono(duree))")
            let fc = recups.compactMap(\.fc)
            if !fc.isEmpty { morceaux.append("la FC redescend à \(fc.reduce(0, +) / fc.count)") }
        }
        return morceaux.isEmpty ? nil : morceaux.joined(separator: " · ")
    }

    // MARK: Allure et FC

    /// Les deux courbes ramenées à la même hauteur : l'allure en haut quand on
    /// va vite, la FC en haut quand elle monte. Les fractions en bandes.
    private var allureEtFC: some View {
        let allures = course.courbe.compactMap(\.allureSKm).map(Double.init)
        let fcs = course.courbe.compactMap(\.fc).map(Double.init)
        let (aMin, aMax) = (allures.min() ?? 0, allures.max() ?? 1)
        let (fMin, fMax) = (fcs.min() ?? 0, fcs.max() ?? 1)
        let total = Double(course.dureeSecondes ?? (course.courbe.last?.t ?? 1))
        return CoquilleWidget(titre: "Allure et FC", icone: "chart.line.uptrend.xyaxis", couleur: Categorie.sport.couleur) {
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(course.fractions) { fraction in
                        RectangleMark(xStart: .value("Début", Double(fraction.debutS) / 60),
                                      xEnd: .value("Fin", Double(fraction.debutS + fraction.dureeS) / 60),
                                      yStart: .value("Bas", 0), yEnd: .value("Haut", 1))
                            .foregroundStyle(Categorie.alerte.couleur.opacity(0.16))
                    }
                    ForEach(course.courbe.indices, id: \.self) { i in
                        let point = course.courbe[i]
                        if let allure = point.allureSKm, aMax > aMin {
                            LineMark(x: .value("Minute", Double(point.t) / 60),
                                     y: .value("Valeur", (aMax - Double(allure)) / (aMax - aMin) * 0.9 + 0.05),
                                     series: .value("Série", "Allure"))
                                .foregroundStyle(Categorie.sport.couleur)
                        }
                        if let fc = point.fc, fMax > fMin {
                            LineMark(x: .value("Minute", Double(point.t) / 60),
                                     y: .value("Valeur", (Double(fc) - fMin) / (fMax - fMin) * 0.9 + 0.05),
                                     series: .value("Série", "FC"))
                                .foregroundStyle(Categorie.alerte.couleur)
                        }
                    }
                }
                .chartYScale(domain: 0...1)
                .chartXScale(domain: 0...(total / 60))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { valeur in
                        AxisValueLabel { Text("\(Int(valeur.as(Double.self) ?? 0)) min") }
                            .foregroundStyle(Palette.texteTertiaire)
                    }
                }
                .frame(height: 150)
                HStack(spacing: 14) {
                    legende("Allure (haut = plus vite)", Categorie.sport.couleur)
                    legende("FC", Categorie.alerte.couleur)
                    if !course.fractions.isEmpty { legende("Fractions", Categorie.alerte.couleur.opacity(0.4)) }
                }
            }
        }
    }

    // MARK: Les zones

    static let couleursZones = [Categorie.cours.couleur, Categorie.sport.couleur, Categorie.menage.couleur,
                                Categorie.alerte.couleur, Categorie.ia.couleur]

    private func zonesCardiaques(_ zones: [Int]) -> some View {
        let total = Double(max(1, zones.reduce(0, +)))
        return CoquilleWidget(titre: "Zones cardiaques", icone: "heart", couleur: Categorie.alerte.couleur,
                              droite: course.fcMaxConnue.map { "FC max \($0)" }) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { rang in
                            if zones[rang] > 0 {
                                Rectangle().fill(Self.couleursZones[rang])
                                    .frame(width: max(3, (geo.size.width - 8) * Double(zones[rang]) / total))
                            }
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)], alignment: .leading,
                          spacing: 6) {
                    ForEach(0..<5, id: \.self) { rang in
                        HStack(spacing: 4) {
                            Circle().fill(Self.couleursZones[rang]).frame(width: 8, height: 8)
                            Text("Z\(rang + 1) \(EnFrancais.duree(minutes: Int((Double(zones[rang]) / 60).rounded())))")
                                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                }
            }
        }
    }

    // MARK: La dynamique de course

    private var tuilesDynamique: [(String, String, String?)] {
        var tuiles: [(String, String, String?)] = []
        let d = course.dynamique
        func ajouter(_ titre: String, _ valeurs: CourseDetaillee.Valeurs?, _ format: (Double) -> String) {
            guard let moyenne = valeurs?.moyenne else { return }
            tuiles.append((titre, format(moyenne), valeurs?.fractions.map { "fractions \(format($0))" }))
        }
        ajouter("Puissance", d?.puissance) { "\(Int($0.rounded())) W" }
        ajouter("Cadence", d?.cadence) { "\(Int($0.rounded())) pas/min" }
        ajouter("Foulée", d?.foulee) { "\($0.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "fr_FR")))) m" }
        ajouter("Contact au sol", d?.contactSol) { "\(Int($0.rounded())) ms" }
        ajouter("Oscillation", d?.oscillation) { "\($0.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "fr_FR")))) cm" }
        if let recup = course.fcRecuperation {
            tuiles.append(("FC de récup", "−\(recup) bpm", "en 1 min, après l'arrêt"))
        }
        return tuiles
    }

    private var dynamique: some View {
        CoquilleWidget(titre: "Dynamique de course", icone: "waveform", couleur: Categorie.ia.couleur, droite: "moyennes") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(tuilesDynamique.indices, id: \.self) { i in
                    let (titre, valeur, detail) = tuilesDynamique[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        Text(valeur).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(detail ?? " ").texte(.legende).foregroundStyle(Palette.texteTertiaire).lineLimit(1)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.verreTeinteForte, in: RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous))
                }
            }
        }
    }
}

// MARK: - La carte

/// Comment colorer le tracé (3.23).
enum ColorationParcours: String, CaseIterable, Hashable {
    case etapes, allure, fc, denivele

    var libelle: String {
        switch self {
        case .etapes: "Étapes"
        case .allure: "Allure"
        case .fc: "FC"
        case .denivele: "Dénivelé"
        }
    }
}

/// Le tracé sur une carte : par morceaux de même couleur, les kilomètres, le
/// départ et l'arrivée. Le tracé ne quitte pas le téléphone ni le serveur (SAN-14).
struct CarteParcours: View {
    let course: CourseDetaillee
    let coloration: ColorationParcours
    let choisi: Int?
    var choisir: ((Int) -> Void)? = nil

    var body: some View {
        Map(initialPosition: .rect(Self.cadre(course.trace))) {
            ForEach(Array(morceaux.enumerated()), id: \.offset) { _, morceau in
                MapPolyline(coordinates: morceau.points)
                    .stroke(morceau.couleur, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let choisi, let portion = troncon(km: choisi), portion.count > 1 {
                MapPolyline(coordinates: portion)
                    .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 11, lineCap: .round))
            }
            if let depart = course.trace.first {
                Annotation("Départ", coordinate: coordonnee(depart), anchor: .center) {
                    Circle().fill(Categorie.sport.couleur).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2.5))
                }
                .annotationTitles(.hidden)
            }
            if let arrivee = course.trace.last {
                Annotation("Arrivée", coordinate: coordonnee(arrivee), anchor: .center) {
                    Circle().fill(.white).frame(width: 12, height: 12)
                }
                .annotationTitles(.hidden)
            }
            ForEach(reperes, id: \.km) { repere in
                Annotation("Km \(repere.km)", coordinate: repere.coordonnee, anchor: .center) {
                    Button { choisir?(repere.km) } label: {
                        Text("\(repere.km)")
                            .font(.system(size: repere.km == choisi ? 12 : 10, weight: .bold))
                            .foregroundStyle(repere.km == choisi ? Palette.texteSurAccent : .white)
                            .frame(width: repere.km == choisi ? 26 : 20, height: repere.km == choisi ? 26 : 20)
                            .background(repere.km == choisi ? .white : Color.black.opacity(0.85), in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    private func coordonnee(_ point: CourseDetaillee.PointTrace) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }

    static func cadre(_ trace: [CourseDetaillee.PointTrace]) -> MKMapRect {
        let points = trace.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
        guard let premier = points.first else { return .world }
        var rect = MKMapRect(origin: premier, size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() { rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0))) }
        let marge = max(rect.width, rect.height) * 0.25 + 200
        return rect.insetBy(dx: -marge, dy: -marge)
    }

    // MARK: Les couleurs

    private struct Morceau {
        var points: [CLLocationCoordinate2D]
        let couleur: Color
    }

    /// Les points voisins de même couleur forment un morceau ; chaque morceau
    /// reprend le dernier point du précédent, pour que le tracé reste continu.
    private var morceaux: [Morceau] {
        var morceaux: [Morceau] = []
        for point in course.trace {
            let couleur = couleur(point)
            let c = coordonnee(point)
            if var dernier = morceaux.last, dernier.couleur == couleur {
                dernier.points.append(c)
                morceaux[morceaux.count - 1] = dernier
            } else {
                let precedent = morceaux.last?.points.last
                morceaux.append(Morceau(points: [precedent, c].compactMap { $0 }, couleur: couleur))
            }
        }
        return morceaux
    }

    private func couleur(_ point: CourseDetaillee.PointTrace) -> Color {
        switch coloration {
        case .etapes:
            return point.rapide ? Categorie.alerte.couleur : Categorie.sport.couleur
        case .allure:
            guard let allure = valeur(point.t, \.allureSKm), let (min, max) = bornes(\.allureSKm) else { return Categorie.sport.couleur }
            return Self.degrade(1 - (allure - min) / Swift.max(1, max - min))
        case .fc:
            guard let fc = valeur(point.t, \.fc), let (min, max) = bornes(\.fc) else { return Categorie.alerte.couleur }
            return Self.degrade((fc - min) / Swift.max(1, max - min))
        case .denivele:
            let altitudes = course.trace.compactMap(\.alt)
            guard let alt = point.alt, let min = altitudes.min(), let max = altitudes.max() else { return Categorie.travail.couleur }
            return Self.degrade((alt - min) / Swift.max(1, max - min))
        }
    }

    /// Trois paliers : bas, moyen, haut.
    static func degrade(_ part: Double) -> Color {
        switch part {
        case ..<0.34: Categorie.travail.couleur
        case ..<0.67: Categorie.sport.couleur
        default: Categorie.alerte.couleur
        }
    }

    private func valeur(_ t: Int, _ chemin: KeyPath<CourseDetaillee.PointCourbe, Int?>) -> Double? {
        let proche = course.courbe.min { abs($0.t - t) < abs($1.t - t) }
        return proche?[keyPath: chemin].map(Double.init)
    }

    private func bornes(_ chemin: KeyPath<CourseDetaillee.PointCourbe, Int?>) -> (Double, Double)? {
        let valeurs = course.courbe.compactMap { $0[keyPath: chemin] }.map(Double.init)
        guard let min = valeurs.min(), let max = valeurs.max() else { return nil }
        return (min, max)
    }

    // MARK: Les kilomètres

    private struct Repere {
        let km: Int
        let coordonnee: CLLocationCoordinate2D
    }

    /// La fin de chaque kilomètre, au point du tracé le plus proche dans le temps.
    private var reperes: [Repere] {
        var fin = 0
        return course.kilometres.compactMap { kilometre in
            fin += kilometre.dureeS
            let cible = fin
            guard let point = course.trace.min(by: { abs($0.t - cible) < abs($1.t - cible) }) else { return nil }
            return Repere(km: kilometre.rang, coordonnee: coordonnee(point))
        }
    }

    private func troncon(km: Int) -> [CLLocationCoordinate2D]? {
        let debut = course.kilometres.prefix(km - 1).map(\.dureeS).reduce(0, +)
        guard let duree = course.kilometres.first(where: { $0.rang == km })?.dureeS else { return nil }
        return course.trace.filter { $0.t >= debut && $0.t <= debut + duree }.map(coordonnee)
    }
}

// MARK: - 3.23 Le parcours en grand

/// 3.23 : la carte en plein écran. Le tracé se colore par étape, allure, FC ou
/// dénivelé ; un kilomètre touché s'ouvre dans la feuille du bas.
struct EcranParcours: View {
    let course: CourseDetaillee
    @Environment(\.dismiss) private var fermer
    @State private var coloration: ColorationParcours = .etapes
    @State private var choisi: Int?

    var body: some View {
        ZStack(alignment: .top) {
            CarteParcours(course: course, coloration: coloration, choisi: choisi) { km in
                withAnimation(.snappy) { choisi = km }
            }
            .ignoresSafeArea()
            VStack(spacing: 12) {
                ZStack {
                    Text("Le parcours").texte(.titreWidget).foregroundStyle(Palette.textePrincipal).surLaPhoto()
                    HStack {
                        BoutonRond("chevron.left", libelle: "Retour") { fermer() }
                        Spacer()
                    }
                }
                .frame(height: 44)
                Segmente(choix: ColorationParcours.allCases.map { ($0, $0.libelle) }, selection: $coloration)
                    .padding(4)
                    .verreControle(Capsule())
            }
            .padding(.horizontal, Espace.marge)
            VStack {
                Spacer()
                feuille
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .ecranHAL()
        .vuParHAL("Le parcours")
        .onAppear { if choisi == nil { choisi = course.kilometres.first?.rang } }
    }

    private var feuille: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(Palette.texteTertiaire).frame(width: 36, height: 5).frame(maxWidth: .infinity)
            if let km = course.kilometres.first(where: { $0.rang == choisi }) {
                let (debut, fin) = bornes(km)
                let etape = course.etapes.first { $0.debutS <= debut + km.dureeS / 2 && debut + km.dureeS / 2 < $0.debutS + $0.dureeS }
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Kilomètre \(km.rang)").texte(.titre).foregroundStyle(Palette.textePrincipal)
                        if let etape { Text(etape.nom).texte(.legende).foregroundStyle(Palette.texteSecondaire) }
                    }
                    Spacer()
                    Puce("\(EnFrancais.chrono(km.dureeS)) /km", categorie: etape?.rapide == true ? .alerte : .sport)
                }
                HStack {
                    valeur("FC moy.", km.fc.map(String.init))
                    valeur("FC max", fcMax(debut, fin).map(String.init))
                    valeur("D+", montee(debut, fin).map { "\($0) m" })
                    valeur("Temps", EnFrancais.chrono(km.dureeS))
                }
            } else {
                Text("Touche un kilomètre pour le voir ici.").texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            profil
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 34)
        .background(.ultraThinMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34))
        .background(Color.black.opacity(0.25), in: UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34))
    }

    private func bornes(_ km: CourseDetaillee.Kilometre) -> (Int, Int) {
        let debut = course.kilometres.prefix(km.rang - 1).map(\.dureeS).reduce(0, +)
        return (debut, debut + km.dureeS)
    }

    private func fcMax(_ debut: Int, _ fin: Int) -> Int? {
        course.courbe.filter { $0.t >= debut && $0.t < fin }.compactMap(\.fc).max()
    }

    private func montee(_ debut: Int, _ fin: Int) -> Int? {
        let altitudes = course.trace.filter { $0.t >= debut && $0.t <= fin }.compactMap(\.alt)
        guard altitudes.count > 1 else { return nil }
        return Int(zip(altitudes, altitudes.dropFirst()).map { max(0, $1 - $0) }.reduce(0, +).rounded())
    }

    private func valeur(_ titre: String, _ valeur: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            Text(valeur ?? "—").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Le profil du dénivelé sur toute la course, le kilomètre choisi en clair.
    private var profil: some View {
        let points = course.trace.filter { $0.alt != nil }
        let total = Double(course.dureeSecondes ?? (points.last?.t ?? 1))
        let distance = Double(course.distanceM ?? 0) / 1000
        let choix = course.kilometres.first { $0.rang == choisi }.map(bornes)
        let altitudes = points.compactMap(\.alt)
        let bas = (altitudes.min() ?? 0) - 2
        let haut = max((altitudes.max() ?? 1) + 2, bas + 10)
        return VStack(spacing: 4) {
            Chart {
                if let choix {
                    RectangleMark(xStart: .value("Début", Double(choix.0) / total * distance),
                                  xEnd: .value("Fin", Double(choix.1) / total * distance))
                        .foregroundStyle(.white.opacity(0.12))
                }
                ForEach(points.indices, id: \.self) { i in
                    AreaMark(x: .value("Km", Double(points[i].t) / total * distance),
                             yStart: .value("Bas", bas), yEnd: .value("Altitude", points[i].alt ?? bas))
                        .foregroundStyle(.white.opacity(0.14))
                    LineMark(x: .value("Km", Double(points[i].t) / total * distance), y: .value("Altitude", points[i].alt ?? 0))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .chartYScale(domain: bas...haut)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { valeur in
                    AxisValueLabel { Text("\(Int(valeur.as(Double.self) ?? 0)) km") }.foregroundStyle(Palette.texteTertiaire)
                }
            }
            .frame(height: 70)
        }
    }
}


// MARK: - La météo de la course

/// MTO-9 : la température, le vent, et la part du parcours face au vent
/// (MTO-7). Relevée par le serveur à la première lecture, puis gardée.
struct CarteMeteoCourse: View {
    let idActivite: Int
    @Environment(Foyer.self) private var foyer
    @State private var meteo: MeteoDeCourse?

    struct MeteoDeCourse: Decodable, Sendable {
        var temperature: Double?
        var ressenti: Double?
        var humidite: Int?
        var ventKmh: Double?
        var rafalesKmh: Double?
        var direction: String?
        var codeTemps: Int?
        var partFace: Double?
        var partDos: Double?
        var allureFaceS: Int?
        var allureDosS: Int?
    }

    var body: some View {
        Group {
            if let meteo {
                CoquilleWidget(titre: "Météo", icone: MeteoDeSeance.icone(meteo.codeTemps),
                               couleur: Categorie.travail.couleur,
                               droite: meteo.temperature.map { "\(Int($0.rounded()))°" }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                chiffre("Ressenti", meteo.ressenti.map { "\(Int($0.rounded()))°" })
                                chiffre("Vent", meteo.ventKmh.map { vent in
                                    "\(Int(vent.rounded())) km/h" + (meteo.direction.map { " \($0)" } ?? "")
                                })
                            }
                            if let face = meteo.partFace, let dos = meteo.partDos {
                                GridRow {
                                    chiffre("Face au vent", "\(Int((face * 100).rounded())) %"
                                            + (meteo.allureFaceS.map { " · \(EnFrancais.chrono($0)) /km" } ?? ""))
                                    chiffre("Dos au vent", "\(Int((dos * 100).rounded())) %"
                                            + (meteo.allureDosS.map { " · \(EnFrancais.chrono($0)) /km" } ?? ""))
                                }
                            }
                        }
                        if meteo.partFace == nil, let vent = meteo.ventKmh, vent < 10 {
                            Text("Vent faible : il n'a pas joué.").texte(.legende)
                                .foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                }
            } else {
                // Une vue vide ne lance pas sa tâche : une place nulle, le temps de lire.
                Color.clear.frame(height: 0)
            }
        }
        .task(id: idActivite) {
            meteo = try? await foyer.demander("GET", "appli/meteo/activite/\(idActivite)")
        }
    }

    private func chiffre(_ titre: String, _ valeur: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            Text(valeur ?? "—").texte(.corpsFort)
                .foregroundStyle(valeur == nil ? Palette.texteTertiaire : Palette.textePrincipal)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
