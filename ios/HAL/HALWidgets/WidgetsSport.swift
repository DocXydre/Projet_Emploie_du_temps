import SwiftUI
import WidgetKit

// IOS-1 : les widgets du sport sur l'écran d'accueil, dont la séance libre.

// MARK: - Séance libre

/// L'entrée d'une séance de musculation non prévue (WID-7) : toucher ouvre
/// l'appli et lance la séance libre, ou reprend celle en cours.
struct WidgetSeanceLibre: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.seance-libre", provider: Lecteur()) { entree in
            VueSeanceLibre(entree: entree).widgetHAL("hal://seance-libre")
        }
        .configurationDisplayName("Séance libre")
        .description("Lance une séance de musculation non prévue.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

private struct VueSeanceLibre: View {
    let entree: Entree
    @Environment(\.widgetFamily) private var famille

    var body: some View {
        let enCours = entree.seance != nil
        if famille == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: enCours ? "dumbbell" : "plus").font(.title2.bold())
            }
            .accessibilityLabel(enCours ? "Reprendre la séance" : "Lancer une séance libre")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 56, height: 56)
                    .background(Teinte.sport, in: Circle())
                Text(enCours ? "Séance en cours" : "Séance libre").font(.subheadline.bold())
                Text(enCours ? "la reprendre" : "chercher un exercice").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Séance en cours

struct WidgetSeanceEnCours: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.seance-en-cours", provider: Lecteur()) { entree in
            VueSeanceEnCours(entree: entree).widgetHAL("hal://seance")
        }
        .configurationDisplayName("Séance en cours")
        .description("L'exercice, la série et le repos de la séance de musculation.")
        .supportedFamilies([.systemMedium])
    }
}

private struct VueSeanceEnCours: View {
    let entree: Entree

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EnTete(titre: "Séance en cours", icone: "dumbbell", couleur: Teinte.sport)
            if let seance = entree.seance {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(seance.etat.exercice).font(.headline).lineLimit(1)
                        Text(seance.etat.serieEnClair).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("Reprendre la séance").font(.caption.bold()).foregroundStyle(Teinte.sport)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        Label {
                            Text(seance.debut, style: .timer).monospacedDigit()
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Teinte.alerte).font(.system(size: 6))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if let repos = seance.etat.repos, repos.upperBound > entree.date {
                            Text("Repos").font(.caption2).foregroundStyle(.secondary)
                            Text(timerInterval: repos, countsDown: true)
                                .monospacedDigit().font(.title2.bold()).multilineTextAlignment(.trailing)
                                .frame(maxWidth: 90, alignment: .trailing)
                        }
                    }
                }
            } else {
                RienAMontrer(texte: "Aucune séance en cours.")
            }
        }
    }
}

// MARK: - Objectif

struct WidgetObjectif: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.objectif", provider: Lecteur()) { entree in
            VueObjectif(entree: entree).widgetHAL("hal://sport")
        }
        .configurationDisplayName("Objectif")
        .description("L'objectif en cours, les jours qui restent et l'avancée.")
        .supportedFamilies([.systemSmall])
    }
}

private struct VueObjectif: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "Objectif", icone: "target", couleur: Teinte.sport) { instantane in
            if let objectif = instantane.objectif {
                VStack(alignment: .leading, spacing: 6) {
                    Text(objectif.titre).font(.subheadline.bold()).lineLimit(2)
                    Spacer(minLength: 0)
                    Text("J−\(objectif.joursRestants)").font(.title2.bold())
                    ProgressView(value: objectif.avancee).tint(Teinte.sport)
                }
            } else {
                RienAMontrer(texte: "Pas d'objectif en cours : dis à HAL ce que tu vises.")
            }
        }
    }
}

// MARK: - Fréquence cardiaque du jour

struct WidgetFrequence: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.frequence", provider: Lecteur()) { entree in
            VueFrequence(entree: entree).widgetHAL("hal://sport")
        }
        .configurationDisplayName("Fréquence cardiaque")
        .description("Ta fréquence cardiaque d'aujourd'hui, lue par la montre.")
        .supportedFamilies([.systemMedium])
    }
}

private struct VueFrequence: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "Fréquence cardiaque · aujourd'hui", icone: "waveform",
              couleur: Teinte.alerte) { instantane in
            let valeurs = instantane.frequence ?? []
            if instantane.sansMontre == true {
                // MON-8 : sans montre, pas de fréquence cardiaque.
                RienAMontrer(texte: "La fréquence cardiaque vient de la montre.")
            } else if valeurs.isEmpty {
                RienAMontrer(texte: "Pas encore de fréquence cardiaque aujourd'hui.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(valeurs.last.map { String(Int($0)) } ?? "—").font(.title2.bold())
                        Text("bpm maintenant").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if let minimum = valeurs.min(), let maximum = valeurs.max() {
                            Text("min \(Int(minimum)) · max \(Int(maximum))").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Courbe(valeurs: valeurs)
                        .stroke(Teinte.alerte, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

/// La courbe d'une suite de valeurs, du plus bas au plus haut de la hauteur.
private struct Courbe: Shape {
    let valeurs: [Double]

    func path(in rect: CGRect) -> Path {
        var chemin = Path()
        guard valeurs.count > 1, let minimum = valeurs.min(), let maximum = valeurs.max() else { return chemin }
        let etendue = max(maximum - minimum, 1)
        for (rang, valeur) in valeurs.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(rang) / CGFloat(valeurs.count - 1),
                                y: rect.maxY - rect.height * CGFloat((valeur - minimum) / etendue))
            if rang == 0 { chemin.move(to: point) } else { chemin.addLine(to: point) }
        }
        return chemin
    }
}

// MARK: - Montre

struct WidgetMontre: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.montre", provider: Lecteur()) { entree in
            VueMontre(entree: entree).widgetHAL("hal://sport")
        }
        .configurationDisplayName("Montre")
        .description("La dernière séance venue de la montre.")
        .supportedFamilies([.systemSmall])
    }
}

private struct VueMontre: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "Montre", icone: "applewatch", couleur: Teinte.sport) { instantane in
            if let seance = instantane.montre {
                VStack(alignment: .leading, spacing: 2) {
                    Text(seance.titre).font(.caption.bold()).lineLimit(1)
                    Text(seance.principal).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    if let fc = seance.fcMoyenne {
                        Text("FC moy. \(fc)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("\(enJour(seance.debut)) \(enHeure(seance.debut))").font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                RienAMontrer(texte: "Aucune séance de la montre.")
            }
        }
    }
}

// MARK: - Dernière course

struct WidgetDerniereCourse: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.derniere-course", provider: Lecteur()) { entree in
            VueDerniereCourse(entree: entree).widgetHAL("hal://sport")
        }
        .configurationDisplayName("Dernière course")
        .description("Distance, durée, allure et fréquence cardiaque de la dernière course.")
        .supportedFamilies([.systemMedium])
    }
}

private struct VueDerniereCourse: View {
    let entree: Entree

    var body: some View {
        let course = entree.instantane?.derniereCourse
        Cadre(entree: entree, titre: course?.titre ?? "Dernière course", icone: "figure.run",
              couleur: Teinte.sport) { _ in
            if let course {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 0) {
                        valeur(course.principal, "distance")
                        valeur(course.duree, "durée")
                        valeur(course.allure, "allure /km")
                        valeur(course.fcMoyenne.map(String.init), "FC moy.")
                    }
                    Spacer(minLength: 0)
                }
            } else {
                RienAMontrer(texte: "Aucune course reçue de la montre.")
            }
        }
    }

    /// APP-4 : une donnée absente s'écrit par un tiret.
    private func valeur(_ texte: String?, _ legende: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(texte ?? "—").font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            Text(legende).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
