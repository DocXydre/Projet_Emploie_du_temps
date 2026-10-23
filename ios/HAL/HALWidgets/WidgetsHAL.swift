import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// Les widgets iOS de HAL (IOS-1 à IOS-3). Ils lisent ce que l'appli a gardé dans
// le dossier partagé, sans appel au serveur. Toucher un widget ouvre l'appli au
// bon endroit, par un lien hal://.

// IOS-1 : chaque widget de l'appli existe aussi sur l'écran d'accueil, à ses
// tailles. Un paquet de widgets en compte dix au plus : ils vont par familles.
@main
struct WidgetsHAL: WidgetBundle {
    var body: some Widget {
        WidgetsDuPlanning().body
        WidgetsDuSport().body
        WidgetsDeLaMaison().body
    }
}

struct WidgetsDuPlanning: WidgetBundle {
    var body: some Widget {
        WidgetMaintenant()
        WidgetJournee()
        WidgetSemaine()
        WidgetWeekEnd()
        WidgetTrain()
        WidgetHAL()
        WidgetOrbe()
    }
}

struct WidgetsDuSport: WidgetBundle {
    var body: some Widget {
        WidgetSeanceLibre()
        WidgetSport()
        WidgetForme()
        WidgetObjectif()
        WidgetFrequence()
        WidgetMontre()
        WidgetDerniereCourse()
        WidgetSeanceEnCours()
        ActiviteDeSeance()
    }
}

struct WidgetsDeLaMaison: WidgetBundle {
    var body: some Widget {
        WidgetACocher()
        WidgetEnRetard()
        WidgetChat()
        WidgetEquilibre()
        WidgetLinge()
        WidgetBientot()
    }
}

// MARK: - Les couleurs

enum Teinte {
    static let sport = Color(red: 0.36, green: 0.88, blue: 0.77)
    static let hal = Color(red: 0.62, green: 0.58, blue: 1.0)
    static let alerte = Color(red: 1.0, green: 0.42, blue: 0.38)
    static let fond = Color(red: 0.07, green: 0.08, blue: 0.10)

    static func categorie(_ nom: String) -> Color {
        switch nom {
        case "cours": Color(red: 1.0, green: 0.54, blue: 0.40)
        case "travail": Color(red: 0.48, green: 0.72, blue: 1.0)
        case "sport": sport
        case "menage": Color(red: 1.0, green: 0.82, blue: 0.40)
        case "linge": Color(red: 0.72, green: 0.58, blue: 0.96)
        case "chat": Color(red: 1.0, green: 0.61, blue: 0.80)
        case "ia": hal
        case "alerte": alerte
        default: Color(red: 0.68, green: 0.72, blue: 0.78)
        }
    }
}

let francais = Locale(identifier: "fr_FR")

// MARK: - La chronologie

struct Entree: TimelineEntry {
    let date: Date
    let instantane: Instantane?
    /// La séance de musculation en cours, s'il y en a une.
    var seance: SeanceEnWidget? = nil
    var motDeHAL: MotDeHAL? = nil

    static let exemple = Entree(date: .now, instantane: .exemple, seance: nil,
                                motDeHAL: MotDeHAL(texte: "Jambes ce soir ? Tu as bien dormi et ta dernière séance date de jeudi."))
}

/// Une entrée tout de suite, puis toutes les quinze minutes : « maintenant » et
/// « ensuite » avancent même sans nouvelle donnée. L'appli redemande un dessin à
/// chaque chargement.
struct Lecteur: TimelineProvider {
    func placeholder(in context: Context) -> Entree {
        .exemple
    }

    func getSnapshot(in context: Context, completion: @escaping (Entree) -> Void) {
        guard !context.isPreview, let lu = Partage.lire() else { return completion(.exemple) }
        completion(Entree(date: .now, instantane: lu, seance: Partage.lire("seance.json"),
                          motDeHAL: Partage.lire("hal.json")))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entree>) -> Void) {
        let lu = Partage.lire()
        let seance: SeanceEnWidget? = Partage.lire("seance.json")
        let motDeHAL: MotDeHAL? = Partage.lire("hal.json")
        let entrees = (0..<8).map { rang in
            Entree(date: Date.now.addingTimeInterval(Double(rang) * 900), instantane: lu,
                   seance: seance, motDeHAL: motDeHAL)
        }
        completion(Timeline(entries: entrees, policy: .atEnd))
    }
}

/// Ce qu'un widget dit quand l'appli n'a encore rien gardé.
struct PasEncore: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "iphone.and.arrow.forward")
            Text("Ouvre HAL une fois").font(.caption2).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Sport : l'anneau de la semaine

struct WidgetSport: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.sport", provider: Lecteur()) { entree in
            VueSport(entree: entree).widgetHAL("hal://sport")
        }
        .configurationDisplayName("Sport")
        .description("Les séances de la semaine, et la prochaine.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
    }
}

struct Anneau: View {
    let faites: Int
    let prevues: Int
    var epaisseur: CGFloat = 8
    var couleur = Teinte.sport

    var body: some View {
        let part = prevues > 0 ? min(1, Double(faites) / Double(prevues)) : 0
        ZStack {
            Circle().stroke(couleur.opacity(0.25), lineWidth: epaisseur)
            Circle().trim(from: 0, to: part)
                .stroke(couleur, style: StrokeStyle(lineWidth: epaisseur, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct VueSport: View {
    let entree: Entree
    @Environment(\.widgetFamily) private var famille

    var body: some View {
        if let sport = entree.instantane?.sport {
            switch famille {
            case .accessoryCircular:
                Gauge(value: Double(sport.faites), in: 0...Double(max(sport.prevues, 1))) {
                    Image(systemName: "figure.run")
                } currentValueLabel: {
                    Text("\(sport.faites)/\(sport.prevues)")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            case .accessoryInline:
                Text("Sport \(sport.faites)/\(sport.prevues)" + (sport.prochaine.map { " · \($0)" } ?? ""))
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sport", systemImage: "figure.run").font(.caption.bold()).foregroundStyle(Teinte.sport)
                    HStack(spacing: 10) {
                        Anneau(faites: sport.faites, prevues: sport.prevues)
                            .frame(width: 52, height: 52)
                            .overlay(Text("\(sport.faites)/\(sport.prevues)").font(.caption.bold()))
                        Text("séance\(sport.prevues > 1 ? "s" : "")\ncette semaine")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let prochaine = sport.prochaine {
                        Text(prochaine).font(.caption.bold()).lineLimit(2)
                    } else {
                        Text("Rien de prévu").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            PasEncore()
        }
    }
}

// MARK: - Forme : la nuit et le repos

struct WidgetForme: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.forme", provider: Lecteur()) { entree in
            VueForme(entree: entree).widgetHAL("hal://sport")
        }
        .configurationDisplayName("Forme")
        .description("Ta nuit, ta fréquence au repos et tes pas.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct VueForme: View {
    let entree: Entree

    var body: some View {
        if let forme = entree.instantane?.forme {
            VStack(alignment: .leading, spacing: 6) {
                Label("Forme", systemImage: "heart").font(.caption.bold()).foregroundStyle(Teinte.alerte)
                Spacer(minLength: 0)
                ligne("bed.double", forme.sommeilMinutes.map { "\($0 / 60) h \(String(format: "%02d", $0 % 60))" })
                ligne("heart", forme.fcRepos.map { "\($0) bpm au repos" })
                ligne("figure.walk", forme.pas.map { "\($0.formatted(.number.locale(francais))) pas" })
                if let vfc = forme.vfc {
                    ligne("waveform.path.ecg", "VFC \(vfc) ms")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            PasEncore()
        }
    }

    private func ligne(_ icone: String, _ valeur: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icone).frame(width: 16).foregroundStyle(.secondary)
            // SAN-5 : une donnée absente reste absente, pas un zéro.
            Text(valeur ?? "pas de donnée").font(.caption).foregroundStyle(valeur == nil ? .secondary : .primary)
        }
    }
}

// MARK: - Ta journée : maintenant et ensuite

struct WidgetJournee: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.journee", provider: Lecteur()) { entree in
            VueJournee(entree: entree).widgetHAL("hal://aujourdhui")
        }
        .configurationDisplayName("Ta journée")
        .description("Ce qui se passe maintenant, et la suite.")
        .supportedFamilies([.systemMedium, .systemSmall, .systemLarge, .accessoryRectangular])
    }
}

private struct VueJournee: View {
    let entree: Entree
    @Environment(\.widgetFamily) private var famille

    var body: some View {
        if let instantane = entree.instantane {
            let suite = instantane.aVenir(entree.date)
            switch famille {
            case .accessoryRectangular:
                if let prochain = suite.first {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(heure(prochain)).font(.caption2.bold())
                        Text(prochain.titre).font(.headline).lineLimit(1)
                        if let lieu = prochain.lieu { Text(lieu).font(.caption2).lineLimit(1) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Rien d'autre aujourd'hui").font(.caption)
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Ta journée", systemImage: "calendar").font(.caption.bold()).foregroundStyle(.secondary)
                    if suite.isEmpty {
                        Spacer(minLength: 0)
                        Text("Rien d'autre aujourd'hui").font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    ForEach(suite.prefix(famille == .systemSmall ? 2 : famille == .systemLarge ? 8 : 3)) { moment in
                        HStack(spacing: 8) {
                            Capsule().fill(Teinte.categorie(moment.categorie)).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(moment.titre).font(.subheadline.bold()).lineLimit(1)
                                Text([heure(moment), moment.lieu].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            PasEncore()
        }
    }

    private func heure(_ moment: Instantane.Moment) -> String {
        if moment.debut <= entree.date, let fin = moment.fin, fin > entree.date {
            return "Maintenant, jusqu'à \(fin.formatted(date: .omitted, time: .shortened))"
        }
        return moment.debut.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - L'orbe : ouvrir HAL depuis l'écran verrouillé

struct WidgetOrbe: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.orbe", provider: Lecteur()) { entree in
            VueOrbe(entree: entree)
                .containerBackground(.clear, for: .widget)
                .widgetURL(URL(string: "hal://hal"))
        }
        .configurationDisplayName("HAL")
        .description("Ouvre directement le panneau de HAL.")
        .supportedFamilies([.accessoryCircular])
    }
}

private struct VueOrbe: View {
    let entree: Entree

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle().strokeBorder(lineWidth: 3).padding(10)
            Circle().frame(width: 10, height: 10)
            if entree.instantane?.halADire == true {
                Text("!").font(.title3.bold()).offset(x: 14, y: -14)
            }
        }
        .accessibilityLabel(entree.instantane?.halADire == true ? "HAL a quelque chose à dire" : "Parler à HAL")
    }
}

// MARK: - La Live Activity de la séance (IOS-3)

struct ActiviteDeSeance: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AttributsSeance.self) { contexte in
            EcranVerrouille(etat: contexte.state, attributs: contexte.attributes)
                .padding(16)
                .activityBackgroundTint(Teinte.fond.opacity(0.85))
                .activitySystemActionForegroundColor(Teinte.sport)
                .widgetURL(URL(string: "hal://seance"))
        } dynamicIsland: { contexte in
            let etat = contexte.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(etat.serieEnClair, systemImage: "dumbbell").font(.caption.bold())
                        .foregroundStyle(Teinte.sport)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let repos = etat.repos {
                        Text(timerInterval: repos, countsDown: true)
                            .monospacedDigit().font(.title3.bold()).multilineTextAlignment(.trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(etat.exercice).font(.headline).lineLimit(1)
                        Spacer()
                        if etat.repos != nil {
                            Button(intent: PasserLeRepos()) {
                                Label("Passer", systemImage: "forward.fill")
                            }
                            .tint(Teinte.sport)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "dumbbell").foregroundStyle(Teinte.sport)
            } compactTrailing: {
                if let repos = etat.repos {
                    Text(timerInterval: repos, countsDown: true)
                        .monospacedDigit().frame(maxWidth: 44)
                } else {
                    Text("S\(etat.serie)").bold()
                }
            } minimal: {
                if let repos = etat.repos {
                    ProgressView(timerInterval: repos, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: "timer")
                    }
                    .progressViewStyle(.circular)
                    .tint(Teinte.sport)
                } else {
                    Image(systemName: "dumbbell").foregroundStyle(Teinte.sport)
                }
            }
            .widgetURL(URL(string: "hal://seance"))
        }
    }
}

private struct EcranVerrouille: View {
    let etat: AttributsSeance.ContentState
    let attributs: AttributsSeance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(attributs.titre, systemImage: "dumbbell").font(.caption.bold()).foregroundStyle(Teinte.sport)
                Spacer()
                Text("\(etat.seriesFaites) série\(etat.seriesFaites > 1 ? "s" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(etat.exercice).font(.headline).lineLimit(1)
                    Text(etat.serieEnClair).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let repos = etat.repos {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Repos").font(.caption2).foregroundStyle(.secondary)
                        Text(timerInterval: repos, countsDown: true)
                            .monospacedDigit().font(.title2.bold()).multilineTextAlignment(.trailing)
                    }
                }
            }
            if let repos = etat.repos {
                HStack {
                    ProgressView(timerInterval: repos, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .tint(Teinte.sport)
                    Button(intent: PasserLeRepos()) { Text("Passer") }
                        .tint(Teinte.sport)
                }
            }
        }
    }
}
