import SwiftUI
import WidgetKit

// IOS-1 : les widgets du planning, de HAL et des voyages, sur l'écran d'accueil.

// MARK: - Maintenant

struct WidgetMaintenant: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.maintenant", provider: Lecteur()) { entree in
            VueMaintenant(entree: entree).widgetHAL("hal://aujourdhui")
        }
        .configurationDisplayName("Maintenant")
        .description("L'événement en cours ou le prochain, et ce qui suit.")
        .supportedFamilies([.systemMedium])
    }
}

private struct VueMaintenant: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "Maintenant", icone: "calendar", couleur: Teinte.categorie("cours")) { instantane in
            let suite = instantane.aVenir(entree.date)
            if let moment = suite.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(moment.titre).font(.title3.bold()).lineLimit(1)
                    Text(horaire(moment)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Text(delai(moment))
                            .font(.caption.bold())
                            .foregroundStyle(Teinte.categorie("travail"))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Teinte.categorie("travail").opacity(0.18), in: Capsule())
                        if suite.count > 1 {
                            Text("Ensuite : \(suite[1].titre) · \(enHeure(suite[1].debut))")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } else {
                RienAMontrer(texte: "Rien de prévu pour le reste de la journée.")
            }
        }
    }

    private func horaire(_ moment: Instantane.Moment) -> String {
        var texte = enHeure(moment.debut)
        if let fin = moment.fin { texte += " – " + enHeure(fin) }
        if let lieu = moment.lieu { texte += " · " + lieu }
        return texte
    }

    private func delai(_ moment: Instantane.Moment) -> String {
        let minutes = Int(moment.debut.timeIntervalSince(entree.date) / 60)
        if minutes <= 0 { return "en cours" }
        if minutes < 60 { return "dans \(minutes) min" }
        return "dans \(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }
}

// MARK: - Semaine

struct WidgetSemaine: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.semaine", provider: Lecteur()) { entree in
            VueSemaine(entree: entree).widgetHAL("hal://aujourdhui")
        }
        .configurationDisplayName("Semaine")
        .description("Les sept jours d'un coup d'œil, chaque bloc à son heure.")
        .supportedFamilies([.systemLarge])
    }
}

/// Les sept jours, de 7 h à 23 h, chaque bloc dans la couleur de sa famille.
private struct VueSemaine: View {
    let entree: Entree
    private let debutJour = 7.0
    private let finJour = 23.0

    var body: some View {
        Cadre(entree: entree, titre: "Semaine", icone: "calendar", couleur: Teinte.categorie("travail")) { instantane in
            let blocs = instantane.semaine ?? []
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Array(jours.enumerated()), id: \.offset) { _, jour in
                        colonne(jour, blocs.filter { Calendar.current.isDate($0.debut, inSameDayAs: jour) })
                    }
                }
                legende(blocs)
            }
        }
    }

    private var jours: [Date] {
        let calendrier = Calendar.current
        let aujourdhui = calendrier.startOfDay(for: entree.date)
        let lundi = calendrier.date(from: calendrier.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                                     from: aujourdhui)) ?? aujourdhui
        return (0..<7).compactMap { calendrier.date(byAdding: .day, value: $0, to: lundi) }
    }

    private func colonne(_ jour: Date, _ blocs: [Instantane.Bloc]) -> some View {
        let aujourdhui = Calendar.current.isDate(jour, inSameDayAs: entree.date)
        return VStack(spacing: 4) {
            Text(String(jour.formatted(.dateTime.weekday(.narrow).locale(francais))).uppercased())
                .font(.caption2.bold())
                .foregroundStyle(aujourdhui ? .primary : .tertiary)
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(aujourdhui ? 0.14 : 0.07))
                    ForEach(Array(blocs.enumerated()), id: \.offset) { _, bloc in
                        let (y, hauteur) = position(bloc, hauteurTotale: geo.size.height)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Teinte.categorie(bloc.categorie))
                            .frame(height: max(4, hauteur))
                            .padding(.horizontal, 3)
                            .offset(y: y)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func position(_ bloc: Instantane.Bloc, hauteurTotale: CGFloat) -> (CGFloat, CGFloat) {
        func heures(_ date: Date) -> Double {
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        }
        let etendue = finJour - debutJour
        let debut = min(max(heures(bloc.debut), debutJour), finJour)
        let fin = min(max(heures(bloc.fin ?? bloc.debut.addingTimeInterval(1800)), debut), finJour)
        return (CGFloat((debut - debutJour) / etendue) * hauteurTotale,
                CGFloat((fin - debut) / etendue) * hauteurTotale)
    }

    private func legende(_ blocs: [Instantane.Bloc]) -> some View {
        let familles: [(String, String)] = [("cours", "Cours"), ("travail", "Travail"), ("sport", "Sport"),
                                            ("menage", "Ménage"), ("linge", "Linge"), ("chat", "Sassy")]
        return HStack(spacing: 10) {
            ForEach(familles.filter { famille in blocs.contains { $0.categorie == famille.0 } }, id: \.0) { famille in
                HStack(spacing: 4) {
                    Circle().fill(Teinte.categorie(famille.0)).frame(width: 6, height: 6)
                    Text(famille.1).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - Week-end

struct WidgetWeekEnd: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.weekend", provider: Lecteur()) { entree in
            VueWeekEnd(entree: entree).widgetHAL("hal://aujourdhui")
        }
        .configurationDisplayName("Week-end")
        .description("Le prochain week-end libre, ou le prochain train.")
        .supportedFamilies([.systemMedium])
    }
}

private struct VueWeekEnd: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "Week-end", icone: "mappin.and.ellipse",
              couleur: Teinte.categorie("travail")) { instantane in
            if let weekend = instantane.weekend {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weekend.titre).font(.headline).lineLimit(2)
                    if let detail = weekend.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                RienAMontrer(texte: "Pas de week-end libre en vue.")
            }
        }
    }
}

// MARK: - Train

struct WidgetTrain: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.train", provider: Lecteur()) { entree in
            VueTrain(entree: entree).widgetHAL("hal://aujourdhui")
        }
        .configurationDisplayName("Train")
        .description("Le prochain train retenu : d'où, vers où, à quelle heure.")
        .supportedFamilies([.systemSmall])
    }
}

private struct VueTrain: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "Train", icone: "tram", couleur: Teinte.categorie("travail")) { instantane in
            if let train = instantane.train, train.depart > entree.date {
                VStack(alignment: .leading, spacing: 2) {
                    Text(train.trajet).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(enHeure(train.depart)).font(.system(size: 30, weight: .bold).monospacedDigit())
                    Spacer(minLength: 0)
                    Text(enJour(train.depart)).font(.caption.bold())
                    Text(train.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                RienAMontrer(texte: "Aucun train retenu.")
            }
        }
    }
}

// MARK: - HAL : son dernier mot

struct WidgetHAL: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.hal", provider: Lecteur()) { entree in
            VueHAL(entree: entree).widgetHAL("hal://hal")
        }
        .configurationDisplayName("HAL")
        .description("La dernière chose que HAL a dite. Toucher ouvre son panneau.")
        .supportedFamilies([.systemMedium])
    }
}

private struct VueHAL: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "HAL", icone: "sparkle", couleur: Teinte.hal,
              droite: entree.instantane?.halADire == true ? "a quelque chose à dire" : nil) { _ in
            VStack(alignment: .leading, spacing: 6) {
                Text(entree.motDeHAL?.texte ?? "HAL n'a encore rien dit.")
                    .font(.subheadline).lineLimit(4)
                Spacer(minLength: 0)
                Text("En parler").font(.caption.bold()).foregroundStyle(Teinte.hal)
            }
        }
    }
}
