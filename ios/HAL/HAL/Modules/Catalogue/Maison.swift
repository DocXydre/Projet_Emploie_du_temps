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
        id: "chat", nom: "Chat", icone: "pawprint", categorie: .chat,
        tailles: [.petit],
        widget: { _ in AnyView(WidgetChat()) }
    )

    static let equilibre = Module(
        id: "equilibre", nom: "Équilibre", icone: "person.2", categorie: .linge,
        tailles: [.petit],
        widget: { _ in AnyView(WidgetEquilibre()) }
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
                                   faite: tache.faite) {
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

struct WidgetChat: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.chat) {
            VStack(alignment: .leading, spacing: 6) {
                ligne("Litière", foyer.chat.litiere)
                ligne("Eau", foyer.chat.eau)
                ligne("Fontaine", foyer.chat.fontaine)
            }
        }
    }

    private func ligne(_ titre: String, _ quand: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            Text(quand).texte(.legende).foregroundStyle(Palette.texteSecondaire)
        }
    }
}

/// La part des tâches faite par chacun.
struct WidgetEquilibre: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.equilibre) {
            VStack(alignment: .leading, spacing: 10) {
                Anneau(valeur: foyer.partDeMoi, couleur: Categorie.linge.couleur, epaisseur: 8,
                       texte: "\(Int((foyer.partDeMoi * 100).rounded())) %")
                    .frame(width: 72, height: 72)
                Text("\(foyer.moi.nom) · \(foyer.autre?.nom ?? "seul")")
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
            }
        }
    }
}
