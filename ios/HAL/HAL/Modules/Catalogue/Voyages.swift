import SwiftUI

extension Module {
    static let weekend = Module(
        id: "weekend", nom: "Week-end", icone: "mappin.and.ellipse", categorie: .travail,
        tailles: [.moyen],
        widget: { _ in AnyView(WidgetWeekEnd()) },
        pourHAL: { foyer in foyer.propositions.first.map { "Week-end libre à \($0.lieu)" } ?? "" }
    )

    static let train = Module(
        id: "train", nom: "Train", icone: "tram", categorie: .travail,
        tailles: [.petit],
        widget: { _ in AnyView(WidgetTrain()) }
    )
}

/// Le prochain week-end libre, et les trains pour y aller [1.13] (WKD, TRJ).
struct WidgetWeekEnd: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var trains: Proposition?

    var body: some View {
        CoquilleWidget(.weekend) {
            if let proposition = foyer.propositions.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Week-end libre à \(proposition.lieu) ?")
                        .texte(.titreWidget).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                    Text("Du \(EnFrancais.jour(proposition.debut)) au \(EnFrancais.jour(proposition.fin))")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                    Spacer(minLength: 0)
                    HStack {
                        Button("Voir les trains") { trains = proposition }
                            .buttonStyle(.hal(.accent))
                        Button("Non merci") { decliner(proposition) }
                            .buttonStyle(.hal(.verre))
                    }
                }
            } else if let train = foyer.prochainTrain {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(train.sens == "aller" ? "Départ" : "Retour") \(EnFrancais.jour(train.depart))")
                        .texte(.titreWidget).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                    Text("Train \(EnFrancais.heure(train.depart)) → \(train.destination)")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                }
            } else {
                VideWidget(texte: "Pas de week-end libre en vue.")
            }
        }
        .sheet(item: $trains) { proposition in
            EcranTrains(proposition: proposition).presentationDetents([.large])
        }
    }

    private func decliner(_ proposition: Proposition) {
        guard foyer.connecte else { return }
        Task {
            do {
                try await foyer.agir("DELETE", "trajets/propositions/\(proposition.id)")
                annoncer("Week-end écarté")
            } catch {
                annoncer((error as? ErreurAPI)?.message ?? "Impossible pour l'instant")
            }
        }
    }
}

/// Le prochain train retenu : d'où, vers où, à quelle heure.
struct WidgetTrain: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.train) {
            if let train = foyer.prochainTrain {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(train.origine) → \(train.destination)")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(EnFrancais.heure(train.depart))
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                        .foregroundStyle(Palette.textePrincipal)
                    Spacer(minLength: 0)
                    Text(EnFrancais.jour(train.depart)).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    Text(EnFrancais.duree(minutes: Int(train.arrivee.timeIntervalSince(train.depart) / 60))
                         + ((train.correspondances ?? 0) > 0 ? " · \(train.correspondances ?? 0) corresp." : ""))
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                }
            } else {
                VideWidget(texte: "Aucun train retenu.")
            }
        }
    }
}
