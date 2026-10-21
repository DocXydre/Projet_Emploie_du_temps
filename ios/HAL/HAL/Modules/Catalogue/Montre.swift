import SwiftUI

extension Module {
    static let montre = Module(
        id: "montre", nom: "Montre", icone: "applewatch", categorie: .sport,
        tailles: [.petit], avecMontre: true,
        widget: { _ in AnyView(WidgetMontre()) },
        ecran: { AnyView(EcranSeancesMontre()) }
    )

    static let derniereCourse = Module(
        id: "derniereCourse", nom: "Dernière course", icone: "figure.run", categorie: .sport,
        tailles: [.moyen],
        widget: { _ in AnyView(WidgetDerniereCourse()) },
        ecran: { AnyView(EcranSeancesMontre()) }
    )
}

/// La dernière séance venue de la montre, par Santé (MON-2). Toucher ouvre le détail [3.14].
struct WidgetMontre: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.montre) {
            if let seance = foyer.seancesDeLaMontre.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Discipline.nom(seance.discipline)).texte(.corpsFort)
                        .foregroundStyle(Palette.textePrincipal).lineLimit(1)
                    Text(principal(seance)).texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    if let fc = seance.fcMoyenne {
                        Text("FC moy. \(fc)").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                    Text("\(EnFrancais.jourCourt(seance.debut)) \(EnFrancais.heure(seance.debut))")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                }
            } else {
                VideWidget(texte: "Aucune séance de la montre.")
            }
        }
    }

    /// La distance pour ce qui se court ou se marche, la durée sinon.
    private func principal(_ seance: HistoriqueSante.Activite) -> String {
        if let metres = seance.distanceM, metres > 0 { return EnFrancais.distance(metres) }
        return seance.dureeSecondes.map { EnFrancais.duree(minutes: $0 / 60) } ?? "—"
    }
}

/// La dernière course : distance, durée, allure, fréquence cardiaque (MON-4).
struct WidgetDerniereCourse: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        let course = foyer.derniereCourse
        CoquilleWidget(titre: course.map { "Dernière course · \(EnFrancais.jour($0.debut))" } ?? "Dernière course",
                       icone: "figure.run", couleur: Categorie.sport.couleur) {
            if let course {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 0) {
                        valeur(course.distanceM.map(EnFrancais.distance), "distance")
                        valeur(course.dureeSecondes.map(EnFrancais.chrono), "durée")
                        valeur(course.allureSKm.map(EnFrancais.chrono), "allure /km")
                        valeur(course.fcMoyenne.map(String.init), "FC moy.")
                    }
                    Spacer(minLength: 0)
                    Text("Le détail dans les séances de la montre")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                }
            } else {
                VideWidget(texte: "Aucune course reçue de la montre.")
            }
        }
    }

    /// APP-4 : une donnée absente s'écrit par un tiret.
    private func valeur(_ texte: String?, _ legende: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(texte ?? "—").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(legende).texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
