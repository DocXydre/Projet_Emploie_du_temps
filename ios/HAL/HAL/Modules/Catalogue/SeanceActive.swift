import SwiftUI

extension Module {
    static let seanceEnCours = Module(
        id: "seanceEnCours", nom: "Séance en cours", icone: "dumbbell", categorie: .sport,
        tailles: [.moyen],
        widget: { _ in AnyView(WidgetSeanceEnCours()) }
    )
}

/// La séance de musculation en cours : l'exercice, la série, le repos (3.5, 3.7).
/// « Reprendre » rouvre l'écran de la séance.
struct WidgetSeanceEnCours: View {
    @Environment(SeanceEnCours.self) private var seance

    var body: some View {
        CoquilleWidget(.seanceEnCours) {
            if seance.enCours, let exercice = seance.exerciceCourant {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exercice.libelle).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                            .lineLimit(1)
                        Text(serie(exercice)).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Reprendre la séance") { seance.affichee = true }
                            .buttonStyle(.hal(.accent))
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Label(EnFrancais.duree(minutes: seance.minutesEcoulees), systemImage: "circle.fill")
                            .labelStyle(EtiquetteIcone(couleur: Categorie.alerte.couleur))
                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        repos
                    }
                }
            } else {
                VideWidget(texte: "Aucune séance en cours.")
            }
        }
    }

    /// « Série 3 sur 4 · 62,5 kg × 6 » : la prochaine série à faire.
    private func serie(_ exercice: ExerciceDeSeance) -> String {
        let faites = seance.series(de: exercice).filter { !$0.intermediaire }.count
        var texte = "Série \(faites + 1)" + (exercice.series.map { " sur \($0)" } ?? "")
        if let charge = exercice.chargeKg, let reps = exercice.repetitionsMax {
            texte += " · \(Poids.texte(charge)) × \(reps)"
        }
        return texte
    }

    /// Le repos qui s'écoule, en anneau, s'il y en a un (SAI-18).
    @ViewBuilder private var repos: some View {
        if let fin = seance.finDuRepos, fin > .now {
            TimelineView(.periodic(from: .now, by: 1)) { contexte in
                let reste = max(0, fin.timeIntervalSince(contexte.date))
                Anneau(valeur: reste / max(1, seance.dureeDuRepos),
                       texte: EnFrancais.chrono(Int(reste.rounded())))
                    .frame(width: 56, height: 56)
            }
        }
    }
}
