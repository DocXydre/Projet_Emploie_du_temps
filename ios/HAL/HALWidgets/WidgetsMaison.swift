import SwiftUI
import WidgetKit

// IOS-1 : les widgets de la maison sur l'écran d'accueil. Toucher ouvre Maison,
// où l'on coche.

// MARK: - À cocher

struct WidgetACocher: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.a-cocher", provider: Lecteur()) { entree in
            VueACocher(entree: entree).widgetHAL("hal://maison")
        }
        .configurationDisplayName("À cocher")
        .description("Les tâches du jour des deux.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct VueACocher: View {
    let entree: Entree
    @Environment(\.widgetFamily) private var famille

    var body: some View {
        Cadre(entree: entree, titre: "À cocher", icone: "checklist", couleur: Teinte.categorie("menage")) { instantane in
            let taches = instantane.taches ?? []
            if taches.isEmpty {
                RienAMontrer(texte: "Aucune tâche aujourd'hui.")
            } else {
                // Ce qui reste à faire d'abord.
                let ordre = taches.filter { !$0.faite } + taches.filter(\.faite)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(ordre.prefix(3).enumerated()), id: \.offset) { _, tache in
                        HStack(spacing: 6) {
                            Image(systemName: tache.faite ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(tache.faite ? Teinte.sport : .secondary)
                            Text(tache.titre).font(.caption).lineLimit(1)
                                .strikethrough(tache.faite).foregroundStyle(tache.faite ? .secondary : .primary)
                            if famille != .systemSmall, let qui = tache.pourQui {
                                Spacer(minLength: 4)
                                Text(qui).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(taches.filter(\.faite).count) sur \(taches.count)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - En retard

struct WidgetEnRetard: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.en-retard", provider: Lecteur()) { entree in
            VueEnRetard(entree: entree).widgetHAL("hal://maison")
        }
        .configurationDisplayName("En retard")
        .description("La tâche qui traîne le plus.")
        .supportedFamilies([.systemSmall])
    }
}

private struct VueEnRetard: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "En retard", icone: "exclamationmark.circle", couleur: Teinte.alerte,
              droite: (entree.instantane?.enRetard?.nombre ?? 0) > 1 ? "\(entree.instantane?.enRetard?.nombre ?? 0)" : nil) { instantane in
            if let tache = instantane.enRetard {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tache.titre).font(.headline).lineLimit(2)
                    Text(tache.detail).font(.caption).foregroundStyle(Teinte.alerte)
                }
            } else {
                RienAMontrer(texte: "Rien ne traîne.")
            }
        }
    }
}

// MARK: - Sassy

struct WidgetChat: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.chat", provider: Lecteur()) { entree in
            VueChat(entree: entree).widgetHAL("hal://maison")
        }
        .configurationDisplayName("Sassy")
        .description("Litière, eau, fontaine : la prochaine fois pour chaque soin.")
        .supportedFamilies([.systemSmall])
    }
}

private struct VueChat: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "Sassy", icone: "pawprint", couleur: Teinte.categorie("chat")) { instantane in
            if let chat = instantane.chat, !chat.soins.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(chat.soins, id: \.titre) { soin in
                        ligne(soin.titre, soin.quand)
                    }
                }
            } else {
                RienAMontrer(texte: "Ouvre HAL une fois")
            }
        }
    }

    private func ligne(_ titre: String, _ quand: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(titre).font(.caption.bold()).lineLimit(1)
            Text(quand).font(.caption2)
                .foregroundStyle(quand == "en retard" ? Teinte.alerte : .secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Équilibre

struct WidgetEquilibre: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.equilibre", provider: Lecteur()) { entree in
            VueEquilibre(entree: entree).widgetHAL("hal://maison")
        }
        .configurationDisplayName("Équilibre")
        .description("Le temps passé aux tâches partagées sur sept jours, par chacun.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct VueEquilibre: View {
    let entree: Entree
    @Environment(\.widgetFamily) private var famille
    /// Moi en bleu, l'autre en lilas, comme dans l'appli.
    private let couleurMoi = Teinte.categorie("travail")
    private let couleurAutre = Teinte.categorie("linge")

    var body: some View {
        Cadre(entree: entree, titre: famille == .systemSmall ? "Équilibre" : "Équilibre de la semaine",
              icone: "person.2", couleur: Teinte.categorie("linge"),
              droite: famille == .systemSmall ? nil : "temps passé") { instantane in
            if let equilibre = instantane.equilibre {
                VStack(alignment: .leading, spacing: 10) {
                    if famille == .systemSmall {
                        HStack(alignment: .firstTextBaseline) {
                            part(equilibre.partDeMoi, "Toi", alignement: .leading)
                            Spacer(minLength: 4)
                            part(1 - equilibre.partDeMoi, equilibre.autre ?? "—", alignement: .trailing)
                        }
                    }
                    barre(equilibre.partDeMoi)
                    Spacer(minLength: 0)
                    if famille == .systemSmall {
                        Text("Temps passé · semaine").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        HStack {
                            personne("Toi · \(equilibre.dureeMoi)", couleurMoi)
                            Spacer()
                            if let autre = equilibre.autre, let duree = equilibre.dureeAutre {
                                personne("\(autre) · \(duree)", couleurAutre)
                            }
                        }
                    }
                }
            } else {
                RienAMontrer(texte: "Ouvre HAL une fois")
            }
        }
    }

    private func part(_ valeur: Double, _ nom: String, alignement: HorizontalAlignment) -> some View {
        VStack(alignment: alignement, spacing: 0) {
            Text("\(Int((valeur * 100).rounded())) %").font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
            Text(nom).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func barre(_ moi: Double) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Capsule().fill(couleurMoi).frame(width: geo.size.width * moi)
                Capsule().fill(couleurAutre)
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }

    private func personne(_ texte: String, _ couleur: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(couleur).frame(width: 8, height: 8)
            Text(texte).font(.caption.bold()).lineLimit(1)
        }
    }
}

// MARK: - Linge

struct WidgetLinge: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.linge", provider: Lecteur()) { entree in
            VueLinge(entree: entree).widgetHAL("hal://maison")
        }
        .configurationDisplayName("Linge")
        .description("La machine, l'étendage, le pliage qui viennent.")
        .supportedFamilies([.systemSmall])
    }
}

private struct VueLinge: View {
    let entree: Entree

    var body: some View {
        Cadre(entree: entree, titre: "Linge", icone: "tshirt", couleur: Teinte.categorie("linge")) { instantane in
            let linge = instantane.linge ?? []
            if linge.isEmpty {
                RienAMontrer(texte: "Pas de linge prévu.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(linge) { ligne in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(ligne.titre).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.8)
                            if let detail = ligne.detail {
                                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Bientôt

struct WidgetBientot: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.docxydre.hal.bientot", provider: Lecteur()) { entree in
            VueBientot(entree: entree).widgetHAL("hal://maison")
        }
        .configurationDisplayName("Bientôt")
        .description("Ce qui arrive les jours suivants, pour les deux.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct VueBientot: View {
    let entree: Entree
    @Environment(\.widgetFamily) private var famille

    var body: some View {
        Cadre(entree: entree, titre: "Bientôt", icone: "calendar", couleur: Teinte.categorie("travail")) { instantane in
            let lignes = (instantane.bientot ?? []).prefix(famille == .systemLarge ? 8 : 3)
            if lignes.isEmpty {
                RienAMontrer(texte: "Rien de prévu les prochains jours.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lignes.enumerated()), id: \.offset) { _, ligne in
                        HStack(spacing: 10) {
                            Text(ligne.detail ?? "").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .leading)
                            Text(ligne.titre).font(.subheadline).lineLimit(1)
                            Spacer(minLength: 0)
                            if let qui = ligne.qui {
                                Text(qui).font(.caption2.bold())
                                    .frame(width: 22, height: 22)
                                    .background(.white.opacity(0.12), in: Circle())
                            }
                        }
                    }
                }
            }
        }
    }
}
