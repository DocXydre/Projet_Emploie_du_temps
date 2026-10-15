import SwiftUI

extension Module {
    static let aCocher = Module(
        id: "aCocher", nom: "À cocher", icone: "checklist", categorie: .menage,
        tailles: [.petit, .moyen],
        widget: { taille in AnyView(WidgetACocher(taille: taille)) },
        agrandi: { AnyView(WidgetACocher(taille: .grand).frame(height: 360)) },
        pourHAL: { foyer in "\(foyer.tachesDuJour.filter { !$0.faite }.count) tâches à faire" }
    )

    static let enRetard = Module(
        id: "enRetard", nom: "En retard", icone: "exclamationmark.circle", categorie: .alerte,
        tailles: [.petit],
        widget: { _ in AnyView(WidgetEnRetard()) }
    )

    static let chat = Module(
        id: "chat", nom: "Sassy", icone: "pawprint", categorie: .chat,
        tailles: [.petit],
        widget: { _ in AnyView(WidgetChat()) }
    )

    static let equilibre = Module(
        id: "equilibre", nom: "Équilibre", icone: "person.2", categorie: .linge,
        tailles: [.petit, .moyen],
        widget: { taille in AnyView(WidgetEquilibre(taille: taille)) }
    )

    static let linge = Module(
        id: "linge", nom: "Linge", icone: "tshirt", categorie: .linge,
        tailles: [.petit],
        widget: { _ in AnyView(WidgetLinge()) }
    )

    static let bientot = Module(
        id: "bientot", nom: "Bientôt", icone: "calendar", categorie: .travail,
        tailles: [.moyen, .grand],
        widget: { taille in AnyView(WidgetBientot(taille: taille)) },
        ecran: { AnyView(EcranPlanning()) }
    )
}

/// Les tâches du jour des deux. On coche aussi celle de l'autre (EXE-14).
struct WidgetACocher: View {
    let taille: TailleWidget
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(Aiguillage.self) private var aiguillage
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        CoquilleWidget(.aCocher) {
            let taches = foyer.tachesDuJour
            if taches.isEmpty && foyer.sansTache && foyer.droits.ajouter {
                VideWidget(texte: "Aucune tâche dans le foyer.", bouton: "Ajouter") {
                    aiguillage.feuille = .ajouterTache
                }
            } else if taches.isEmpty {
                VideWidget(texte: "Aucune tâche aujourd'hui.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(taches.prefix(limite)) { tache in
                        LigneTache(titre: tache.titre,
                                   pourQui: taille == .petit ? nil : tache.pourQui.nom,
                                   faite: tache.faite,
                                   type: tache.type.map { ($0.icone, tache.couleur) }) {
                            cocher(tache)
                        }
                        .contextMenu {
                            if tache.reportable && !tache.faite {
                                Button("Repousser", systemImage: "arrow.uturn.forward") {
                                    withAnimation(.snappy) { foyer.reporter(tache, file: file) }
                                    annoncer("« \(tache.titre) » repoussée")
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(taches.filter(\.faite).count) sur \(taches.count)")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                }
            }
        }
    }

    /// Cocher se confirme en haut de l'écran, avec cinq secondes pour annuler (ORB-6).
    private func cocher(_ tache: Tache) {
        guard !tache.faite else { return }
        var annuler: (() -> Void)?
        withAnimation(.snappy) { annuler = foyer.cocher(tache, file: file) }
        if let annuler {
            annoncer("« \(tache.titre) » faite", annuler: { withAnimation(.snappy) { annuler() } })
        }
    }

    private var limite: Int {
        switch taille {
        case .petit: 3
        case .moyen: 3
        case .grand: 10
        }
    }
}

/// La tâche la plus en retard, et le geste pour la prendre.
struct WidgetEnRetard: View {
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        CoquilleWidget(.enRetard) {
            if let tache = foyer.tachesEnRetard.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tache.titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                    Text(tache.reports > 0 ? "reportée \(tache.reports) fois" : Dates.depuis(tache.fin)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    Spacer(minLength: 0)
                    Button("C'est fait") {
                        var annuler: (() -> Void)?
                        withAnimation(.snappy) { annuler = foyer.cocher(tache, file: file) }
                        if let annuler {
                            annoncer("« \(tache.titre) » faite", annuler: { withAnimation(.snappy) { annuler() } })
                        }
                    }
                        .buttonStyle(.hal(.verreAccent, pleineLargeur: true))
                }
            } else {
                VideWidget(texte: "Rien ne traîne.")
            }
        }
    }
}

/// Litière, eau, fontaine : la prochaine fois pour chaque soin du chat (4.1).
struct WidgetChat: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.chat) {
            VStack(alignment: .leading, spacing: 4) {
                ligne("Litière", foyer.chat.litiere)
                ligne("Eau", foyer.chat.eau)
                ligne("Fontaine", foyer.chat.fontaine)
            }
        }
    }

    private func ligne(_ titre: String, _ quand: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
            Text(quand).texte(.legende)
                .foregroundStyle(quand == "en retard" ? Categorie.alerte.couleur : Palette.texteSecondaire)
                .lineLimit(1)
        }
    }
}

/// Le temps passé aux tâches partagées sur sept jours, par chacun (EXE, 4.1).
struct WidgetEquilibre: View {
    var taille: TailleWidget = .petit
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(titre: taille == .petit ? "Équilibre" : "Équilibre de la semaine",
                       icone: "person.2", couleur: Categorie.linge.couleur,
                       droite: taille == .petit ? nil : "temps passé") {
            let moi = foyer.partDeMoi
            VStack(alignment: .leading, spacing: 10) {
                if taille == .petit {
                    HStack(alignment: .firstTextBaseline) {
                        part(moi, "Toi", alignement: .leading)
                        Spacer(minLength: 4)
                        part(1 - moi, foyer.autre?.nom ?? "—", alignement: .trailing)
                    }
                }
                barre(moi)
                if taille == .petit {
                    Spacer(minLength: 0)
                    Text("Temps passé · semaine").texte(.legende).foregroundStyle(Palette.texteTertiaire)
                } else {
                    HStack {
                        personne(foyer.moi, "Toi")
                        Spacer()
                        if let autre = foyer.autre { personne(autre, autre.nom) }
                    }
                }
            }
        }
    }

    private func part(_ valeur: Double, _ nom: String, alignement: HorizontalAlignment) -> some View {
        VStack(alignment: alignement, spacing: 0) {
            Text("\(Int((valeur * 100).rounded())) %").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(nom).texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
        }
    }

    private func barre(_ moi: Double) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Capsule().fill(foyer.couleur(de: foyer.moi)).frame(width: geo.size.width * moi)
                Capsule().fill(foyer.couleur(de: foyer.autre))
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }

    private func personne(_ membre: Membre, _ nom: String) -> some View {
        HStack(spacing: 8) {
            Avatar(nom: membre.nom, couleur: foyer.couleur(de: membre), taille: 28)
            Text("\(nom) · \(EnFrancais.duree(minutes: foyer.minutesFaites[membre.id] ?? 0))")
                .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
        }
    }
}

/// Le linge qui vient : la machine, l'étendage, le pliage (4.1).
struct WidgetLinge: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.linge) {
            let linge = Array(foyer.lingeAVenir.prefix(2))
            if linge.isEmpty {
                VideWidget(texte: "Pas de linge prévu.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(linge, id: \.cle) { element in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(element.libelle).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(quand(element)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                }
            }
        }
    }

    private func quand(_ element: ElementPlanning) -> String {
        let jour = Calendar.current.isDateInToday(element.debut) ? "aujourd'hui" : EnFrancais.jour(element.debut)
        return element.journeeEntiere == true ? jour : "\(jour) · \(EnFrancais.heure(element.debut))"
    }
}

/// Ce qui arrive les jours suivants, pour les deux (4.1). Toucher ouvre le planning [1.12].
struct WidgetBientot: View {
    let taille: TailleWidget
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.bientot) {
            let lignes = Array(foyer.bientot.prefix(taille == .grand ? 8 : 3))
            if lignes.isEmpty {
                VideWidget(texte: "Rien de prévu les prochains jours.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lignes, id: \.cle) { element in
                        HStack(spacing: 10) {
                            Text(EnFrancais.jourCourt(element.debut))
                                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                .frame(width: 36, alignment: .leading)
                            Text(element.libelle).texte(.corps).foregroundStyle(Palette.textePrincipal)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let membre = foyer.membre(numero: element.idUtilisateur), foyer.membres.count > 1 {
                                Avatar(nom: membre.nom, couleur: foyer.couleur(de: membre), taille: 24)
                            }
                        }
                    }
                }
            }
        }
    }
}
