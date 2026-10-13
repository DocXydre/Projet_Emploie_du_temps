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
        tailles: [.moyen],
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
                    Text("de sommeil").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            } else {
                HStack(alignment: .top) {
                    valeur("Sommeil", sommeil(forme.sommeilMinutes))
                    valeur("FC repos", forme.fcRepos.map(String.init) ?? "—", "bpm")
                    valeur("VFC", forme.vfc.map(String.init) ?? "—", "ms")
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

    var body: some View {
        CoquilleWidget(.objectif) {
            VStack(alignment: .leading, spacing: 6) {
                Text(foyer.objectif.titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal).lineLimit(2)
                Spacer(minLength: 0)
                Text("J−\(foyer.objectif.joursRestants)").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                ProgressView(value: foyer.objectif.avancee).tint(Categorie.sport.couleur)
            }
        }
    }
}

struct WidgetFrequence: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.frequenceDuJour) {
            let valeurs = foyer.frequenceDuJour.compactMap(\.valeur)
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

struct WidgetSeanceLibre: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.surPrincipal)
                .frame(width: 64, height: 64)
                .background(theme.principal, in: Circle())
            Text("Séance libre").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            Text("chercher un exercice").texte(.legende).foregroundStyle(Palette.texteSecondaire)
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

    var body: some View {
        CoquilleWidget(titre: "Séance du jour · \(foyer.seance.heure)", icone: "dumbbell", couleur: Categorie.sport.couleur) {
            VStack(alignment: .leading, spacing: 6) {
                Text(foyer.seance.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                Text("\(foyer.seance.exercices.count) exercices · \(foyer.seance.duree)")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                Spacer(minLength: 0)
                HStack {
                    Button("Lancer la séance") {}
                        .buttonStyle(.hal(.accent, pleineLargeur: true))
                    Button("Déjà faite") {}
                        .buttonStyle(.hal(.verre))
                }
            }
        }
    }
}

/// La séance du jour en grand : ses exercices et la consigne de HAL.
struct VueSeanceDuJour: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(titre: "Séance du jour", icone: "dumbbell", couleur: Categorie.sport.couleur) {
            VStack(alignment: .leading, spacing: 10) {
                Text(foyer.seance.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                ForEach(Array(foyer.seance.exercices.enumerated()), id: \.offset) { element in
                    HStack {
                        Text("\(element.offset + 1)").texte(.corpsFort).foregroundStyle(Palette.texteTertiaire).frame(width: 20)
                        Text(element.element).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    }
                }
                Text(foyer.seance.consigne).texte(.legende).foregroundStyle(Categorie.ia.couleur)
            }
        }
        .frame(height: 340)
    }
}

/// Une fenêtre de mesure ouverte par HAL (MES-1).
struct WidgetMesureDemandee: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        let mesure = foyer.mesureEnCours
        CoquilleWidget(titre: "Mesure demandée · \(mesure.jusquA)", icone: "scalemass", couleur: Categorie.ia.couleur) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mesure.titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                Text(mesure.consigne).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                Spacer(minLength: 0)
                HStack {
                    Button("Saisir") {}.buttonStyle(.hal(.accent, pleineLargeur: true))
                    Button("Pas possible") { foyer.essais.mesure = false }.buttonStyle(.hal(.verre))
                }
            }
        }
    }
}
