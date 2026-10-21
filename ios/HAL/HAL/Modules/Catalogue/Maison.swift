import SwiftUI

extension Module {
    static let aCocher = Module(
        id: "aCocher", nom: "À cocher", icone: "checklist", categorie: .menage,
        tailles: [.petit, .moyen],
        widget: { taille in AnyView(WidgetACocher(taille: taille)) },
        agrandi: { AnyView(VueACocher()) },
        pourHAL: { foyer in "\(foyer.tachesDuJour.filter { !$0.faite }.count) tâches à faire" }
    )

    static let enRetard = Module(
        id: "enRetard", nom: "En retard", icone: "exclamationmark.circle", categorie: .alerte,
        tailles: [.petit],
        widget: { _ in AnyView(WidgetEnRetard()) },
        // WID-5 : le widget ouvre tout ce qui traîne [4.5].
        ecran: { AnyView(EcranCeQuiTraine()) }
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
                                   type: tache.type.map { ($0.icone, tache.couleur) },
                                   annulableJusqua: foyer.departDeLEnvoi(tache)) {
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

    /// Cocher se confirme en haut de l'écran ; l'envoi attend trente secondes (APP-10).
    private func cocher(_ tache: Tache) {
        // APP-10 : une tâche cochée se décoche d'un geste tant qu'elle n'est pas partie.
        guard !tache.faite else {
            var decochee = false
            withAnimation(.snappy) { decochee = foyer.decocher(tache) }
            if decochee { annoncer("« \(tache.titre) » décochée") }
            return
        }
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

/// 1.8 : les tâches du jour des deux, par personne, avec l'avancée. Cocher
/// celle de l'autre la crédite à qui l'a faite, et l'autre est prévenu (EXE-14, EXE-16).
struct VueACocher: View {
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(Aiguillage.self) private var aiguillage
    @Environment(\.annoncer) private var annoncer
    @Environment(\.fermerAgrandi) private var fermerAgrandi
    @Environment(\.theme) private var theme

    var body: some View {
        let taches = foyer.tachesDuJour
        let faites = taches.filter(\.faite).count
        CoquilleWidget(titre: "À cocher · Aujourd'hui", icone: "checklist", couleur: Categorie.menage.couleur) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(faites) sur \(taches.count) faite\(faites > 1 ? "s" : "")")
                    .texte(.titre).foregroundStyle(Palette.textePrincipal)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.verreTeinteForte)
                        Capsule().fill(theme.principal)
                            .frame(width: geo.size.width * CGFloat(faites) / CGFloat(max(1, taches.count)))
                    }
                }
                .frame(height: 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(foyer.membres) { membre in
                            let siennes = taches.filter { $0.pourQui == membre }
                            if !siennes.isEmpty {
                                HStack(spacing: 8) {
                                    Avatar(nom: membre.nom, couleur: foyer.couleur(de: membre), taille: 24)
                                    Text(membre.nom).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                }
                                ForEach(siennes) { tache in
                                    LigneTache(titre: tache.titre, faite: tache.faite,
                                               detail: detail(tache), detailEnAlerte: tache.enRetard && !tache.faite,
                                               type: tache.type.map { ($0.icone, tache.couleur) },
                                               annulableJusqua: foyer.departDeLEnvoi(tache)) {
                                        cocher(tache)
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                HStack {
                    Button("Tâche faite en plus") {
                        fermerAgrandi?.fermer()
                        aiguillage.feuille = .tacheFaite
                    }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                    Button("Ouvrir Maison") {
                        fermerAgrandi?.fermer()
                        aiguillage.onglet = .maison
                    }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                }
            }
        }
        .frame(maxHeight: 600)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// « 21:00 », « Fait », ou « En retard de 2 jours ».
    private func detail(_ tache: Tache) -> String? {
        if tache.faite { return "Fait" }
        if tache.enRetard, let fin = tache.fin {
            let jours = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: fin),
                                                        to: Calendar.current.startOfDay(for: .now)).day ?? 0
            return jours > 0 ? "En retard de \(jours) jour\(jours > 1 ? "s" : "")" : "En retard"
        }
        guard !tache.journeeEntiere, let debut = tache.debut else { return nil }
        return EnFrancais.heure(debut)
    }

    private func cocher(_ tache: Tache) {
        guard !tache.faite else {
            var decochee = false
            withAnimation(.snappy) { decochee = foyer.decocher(tache) }
            if decochee { annoncer("« \(tache.titre) » décochée") }
            return
        }
        var annuler: (() -> Void)?
        withAnimation(.snappy) { annuler = foyer.cocher(tache, file: file) }
        if let annuler {
            annoncer("« \(tache.titre) » faite", annuler: { withAnimation(.snappy) { annuler() } })
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

/// 4.5 : ce qui traîne, avec son retard et ses reports ; « Fait », « Demain »
/// ou « Refuser », pour soi comme pour l'autre (EXE-4, EXE-6, EXE-12).
struct EcranCeQuiTraine: View {
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var envoi: Int?

    var body: some View {
        let taches = foyer.tachesEnRetard
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                BarrePoussee(titre: "Ce qui traîne") { fermer() }
                if taches.isEmpty {
                    CarteVide(icone: "checkmark.circle", categorie: .sport, titre: "Rien ne traîne",
                              texte: "Tout ce qui était prévu est fait, ou à venir.")
                }
                ForEach(taches) { tache in
                    carte(tache)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
        .refreshable { await foyer.charger() }
    }

    private func carte(_ tache: Tache) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tache.titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Text(retard(tache)).texte(.legende)
                        .foregroundStyle(jours(tache) >= 2 ? Categorie.alerte.couleur : Palette.texteSecondaire)
                }
                Spacer(minLength: 8)
                if foyer.membres.count > 1 {
                    Avatar(nom: tache.pourQui.nom, couleur: foyer.couleur(de: tache.pourQui), taille: 28)
                }
            }
            HStack(spacing: 8) {
                Button("Fait") { faire(tache) }.buttonStyle(.hal(.accent, pleineLargeur: true))
                if tache.reportable {
                    Button("Demain") { reporter(tache) }.buttonStyle(.hal(.verre, pleineLargeur: true))
                }
                Button("Refuser") { Task { await refuser(tache) } }.buttonStyle(.hal(.verre, pleineLargeur: true))
            }
            .disabled(envoi == tache.id)
        }
        .padding(Espace.interne)
        .carte()
    }

    private func jours(_ tache: Tache) -> Int {
        guard let fin = tache.fin else { return 0 }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: fin),
                                               to: Calendar.current.startOfDay(for: .now)).day ?? 0
    }

    /// « En retard de 2 jours · reporté 1 fois »
    private func retard(_ tache: Tache) -> String {
        let n = jours(tache)
        var texte = n <= 0 ? "Aujourd'hui" : n == 1 ? "En retard d'1 jour" : "En retard de \(n) jours"
        if tache.reports > 0 { texte += " · reporté \(tache.reports) fois" }
        return texte
    }

    private func faire(_ tache: Tache) {
        var annuler: (() -> Void)?
        withAnimation(.snappy) { annuler = foyer.cocher(tache, file: file) }
        if let annuler {
            annoncer("« \(tache.titre) » faite", annuler: { withAnimation(.snappy) { annuler() } })
        }
    }

    private func reporter(_ tache: Tache) {
        withAnimation(.snappy) { foyer.reporter(tache, file: file) }
        annoncer("« \(tache.titre) » repoussée")
    }

    /// Refuser : elle est soldée, et l'autre peut la reprendre.
    private func refuser(_ tache: Tache) async {
        envoi = tache.id
        defer { envoi = nil }
        do {
            try await foyer.agir("POST", "occurrences/\(tache.id)/refuser")
            annoncer("« \(tache.titre) » refusée")
        } catch {
            annoncer((error as? ErreurAPI)?.message ?? "Refus impossible")
        }
    }
}
