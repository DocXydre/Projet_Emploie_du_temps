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
            if let objectif = foyer.objectifEnCours {
                VStack(alignment: .leading, spacing: 6) {
                    Text(objectif.titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal).lineLimit(2)
                    Spacer(minLength: 0)
                    Text("J−\(objectif.joursRestants)").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                    ProgressView(value: objectif.avancee).tint(Categorie.sport.couleur)
                }
            } else {
                VideWidget(texte: "Pas encore d'objectif : HAL t'en propose un au démarrage.")
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
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file

    var body: some View {
        Button { seance.lancerLibre(file: file) } label: { contenu }
            .buttonStyle(.plain)
    }

    private var contenu: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.surPrincipal)
                .frame(width: 64, height: 64)
                .background(theme.principal, in: Circle())
            Text(seance.enCours ? "Séance en cours" : "Séance libre").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            Text(seance.enCours ? "la reprendre" : "chercher un exercice").texte(.legende).foregroundStyle(Palette.texteSecondaire)
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
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        let jour = foyer.seanceAPrevoir ?? foyer.seance
        CoquilleWidget(titre: "Séance du jour · \(jour.heure)", icone: "dumbbell", couleur: Categorie.sport.couleur) {
            VStack(alignment: .leading, spacing: 6) {
                Text(jour.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                Text("\(jour.exercices.count) exercices · \(jour.duree)")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                Spacer(minLength: 0)
                HStack {
                    Button(seance.enCours ? "Reprendre" : "Lancer la séance") {
                        if let detail = foyer.seanceDuJour { seance.lancer(detail) } else { seance.affichee = seance.enCours }
                    }
                    .buttonStyle(.hal(.accent, pleineLargeur: true))
                    if !seance.enCours, let detail = foyer.seanceDuJour {
                        Button("Déjà faite") {
                            SeanceEnCours.dejaFaite(detail, file: file)
                            annoncer("Séance comptée faite")
                        }
                        .buttonStyle(.hal(.verre))
                    }
                }
            }
        }
    }
}

/// La séance du jour en grand : ses exercices et la consigne de HAL.
struct VueSeanceDuJour: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        let jour = foyer.seanceAPrevoir ?? foyer.seance
        CoquilleWidget(titre: "Séance du jour", icone: "dumbbell", couleur: Categorie.sport.couleur) {
            VStack(alignment: .leading, spacing: 10) {
                Text(jour.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                ForEach(jour.exercices.indices, id: \.self) { rang in
                    HStack {
                        Text("\(rang + 1)").texte(.corpsFort).foregroundStyle(Palette.texteTertiaire).frame(width: 20)
                        Text(jour.exercices[rang]).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    }
                }
                if !jour.consigne.isEmpty {
                    Text(jour.consigne).texte(.legende).foregroundStyle(Categorie.ia.couleur)
                }
            }
        }
        .frame(height: 340)
    }
}

/// Une fenêtre de mesure ouverte par HAL (MES-1).
struct WidgetMesureDemandee: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var saisir = false

    var body: some View {
        let mesure = foyer.mesureDemandee ?? foyer.mesureEnCours
        CoquilleWidget(titre: "Mesure demandée · \(mesure.jusquA)", icone: "scalemass", couleur: Categorie.ia.couleur) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mesure.titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                Text(mesure.consigne).texte(.corps).foregroundStyle(Palette.texteSecondaire).lineLimit(2)
                Spacer(minLength: 0)
                HStack {
                    Button("Saisir") { saisir = true }.buttonStyle(.hal(.accent, pleineLargeur: true))
                    Button("Pas possible") { reporter(mesure) }.buttonStyle(.hal(.verre))
                }
            }
        }
        .sheet(isPresented: $saisir) {
            FeuilleMesure(mesure: mesure).presentationDetents([.medium]).feuilleEnVerre()
        }
    }

    /// MES-3 : « Je ne peux pas » repousse la fenêtre, sans reproche.
    private func reporter(_ mesure: MesureDemandee) {
        guard foyer.connecte else {
            foyer.essais.mesure = false
            return
        }
        Task {
            do {
                try await foyer.agir("POST", "mesures/fenetres/\(mesure.id)/reporter")
                annoncer("Mesure repoussée")
            } catch {
                annoncer((error as? ErreurAPI)?.message ?? "Impossible pour l'instant")
            }
        }
    }
}

/// 3.19 : saisir une mesure.
struct FeuilleMesure: View {
    let mesure: MesureDemandee
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var valeur: Double = 70
    @State private var erreur: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Espace.gouttiere) {
            Text(mesure.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
            Text(mesure.consigne).texte(.corps).foregroundStyle(Palette.texteSecondaire)
            Compteur(titre: TypeMesure.unite(mesure.type) == "kg" ? "Poids" : "Mesure", valeur: $valeur,
                     pas: TypeMesure.unite(mesure.type) == "m" ? 50 : 0.5, bornes: 1...20_000,
                     unite: TypeMesure.unite(mesure.type))
            if let erreur {
                Label(erreur, systemImage: "exclamationmark.circle").foregroundStyle(Categorie.alerte.couleur)
            }
            Button("Enregistrer") { Task { await enregistrer() } }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
        }
        .padding(Espace.marge)
        .onAppear {
            switch TypeMesure.unite(mesure.type) {
            case "kg": valeur = 70
            case "m": valeur = 2400
            default: valeur = 40
            }
        }
    }

    private struct Envoi: Encodable {
        let type: String
        let valeur: Double
        let unite: String
    }

    private func enregistrer() async {
        guard foyer.connecte else {
            foyer.essais.mesure = false
            fermer()
            return
        }
        do {
            try await foyer.agir("POST", "mesures", corps: ClientAPI.corps(Envoi(
                type: mesure.type, valeur: valeur, unite: TypeMesure.unite(mesure.type))))
            annoncer("Mesure enregistrée")
            fermer()
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
