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
    @Environment(ConversationHAL.self) private var conversation

    var body: some View {
        CoquilleWidget(.objectif) {
            if let objectif = foyer.objectifEnCours {
                VStack(alignment: .leading, spacing: 6) {
                    Text(objectif.titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal).lineLimit(2)
                    Spacer(minLength: 0)
                    Text("J−\(objectif.joursRestants)").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                    ProgressView(value: objectif.avancee).tint(Categorie.sport.couleur)
                }
            } else if foyer.demarrageDeHAL != nil {
                VideWidget(texte: "Pas encore d'objectif.", bouton: "Démarrer HAL") {
                    conversation.demarrageOuvert = true
                }
            } else {
                VideWidget(texte: "Pas d'objectif en cours : dis à HAL ce que tu vises.")
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
    @State private var supprimer = false

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
                        if detail.seance.libre == true && detail.saisi.isEmpty {
                            // SAI-19 : une séance libre ouverte par erreur, sans rien dedans.
                            Button("Supprimer") { supprimer = true }
                                .buttonStyle(.hal(.verre))
                        } else {
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
        .confirmationDialog("Supprimer cette séance libre ?", isPresented: $supprimer, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                guard let id = foyer.seanceDuJour?.seance.idOccurrence else { return }
                Task {
                    do {
                        try await foyer.agir("DELETE", "seances/\(id)/libre")
                        annoncer("Séance libre supprimée")
                    } catch {
                        annoncer((error as? ErreurAPI)?.message ?? "Suppression impossible")
                    }
                }
            }
        } message: {
            Text("Elle a été lancée par erreur : elle disparaît, sans rien laisser.")
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
                    AvisDeHAL(texte: jour.consigne, style: .legende, secondaire: true)
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
            FeuilleMesure(mesure: mesure).presentationDetents([.large]).feuilleEnVerre()
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

/// 3.19 : saisir une mesure. Un test de course se donne en minutes et secondes,
/// sur deux roues comme le minuteur d'iOS : tout tient dans la largeur.
struct FeuilleMesure: View {
    let mesure: MesureDemandee
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var valeur: Double = 70
    @State private var minutes = 15
    @State private var secondes = 0
    @State private var envoi = false
    @State private var erreur: String?

    private var unite: String { TypeMesure.unite(mesure.type) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Espace.gouttiere) {
                    if !mesure.consigne.isEmpty {
                        AvisDeHAL(texte: mesure.consigne, secondaire: true)
                    }
                    saisie
                    if let erreur {
                        Label(erreur, systemImage: "exclamationmark.circle")
                            .foregroundStyle(Categorie.alerte.couleur)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(envoi ? "Envoi…" : "Enregistrer") { Task { await enregistrer() } }
                        .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                        .disabled(envoi || (unite == "s" && minutes * 60 + secondes <= 0))
                }
                .padding(Espace.marge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .containerBackground(.clear, for: .navigation)
            .navigationTitle(mesure.titre)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer", systemImage: "xmark") { fermer() }
                }
            }
        }
        .onAppear {
            switch unite {
            case "kg": valeur = 70
            case "reps": valeur = 10
            default: valeur = 40
            }
        }
    }

    @ViewBuilder private var saisie: some View {
        switch unite {
        case "s":
            HStack(spacing: 0) {
                roue("Minutes", selection: $minutes, valeurs: 0...180, suffixe: "min")
                roue("Secondes", selection: $secondes, valeurs: 0...59, suffixe: "s")
            }
            .frame(height: 170)
            .padding(.horizontal, Espace.serre)
            .carte(rayon: Rayon.controle)
        case "reps":
            Compteur(titre: "Répétitions", valeur: $valeur, pas: 1, bornes: 1...500)
        case "kg":
            Compteur(titre: "Poids", valeur: $valeur, pas: 0.1, bornes: 20...300, unite: "kg")
        default:
            Compteur(titre: "Tour", valeur: $valeur, pas: 0.5, bornes: 10...200, unite: "cm")
        }
    }

    private func roue(_ titre: String, selection: Binding<Int>, valeurs: ClosedRange<Int>,
                      suffixe: String) -> some View {
        Picker(titre, selection: selection) {
            ForEach(Array(valeurs), id: \.self) { nombre in
                Text("\(nombre) \(suffixe)").foregroundStyle(Palette.textePrincipal).tag(nombre)
            }
        }
        .pickerStyle(.wheel)
        .frame(maxWidth: .infinity)
        .clipped()
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
        envoi = true
        defer { envoi = false }
        let nombre = unite == "s" ? Double(minutes * 60 + secondes) : (valeur * 10).rounded() / 10
        do {
            try await foyer.agir("POST", "mesures", corps: ClientAPI.corps(Envoi(
                type: mesure.type, valeur: nombre, unite: unite)))
            annoncer("Mesure enregistrée")
            fermer()
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
