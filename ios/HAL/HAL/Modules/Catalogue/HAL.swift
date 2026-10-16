import SwiftUI

extension Module {
    static let hal = Module(
        id: "hal", nom: "HAL", icone: "sparkle", categorie: .ia,
        tailles: [.moyen],
        widget: { _ in AnyView(WidgetHAL()) }
    )

    static let ajustement = Module(
        id: "ajustement", nom: "HAL propose", icone: "sparkle", categorie: .ia,
        tailles: [.moyen],
        widget: { _ in AnyView(WidgetAjustement()) },
        // WID-5 : l'ajustement ouvre son détail [3.21].
        ecran: { AnyView(EcranAjustement()) }
    )
}

/// La dernière chose que HAL a dite.
struct WidgetHAL: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation

    var body: some View {
        CoquilleWidget(.hal) {
            VStack(alignment: .leading, spacing: 10) {
                Text(dernierMot)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal).lineLimit(3)
                Spacer(minLength: 0)
                HStack {
                    if !foyer.connecte {
                        Button("Oui, jeu. 18:00") {}
                            .buttonStyle(.hal(.verreAccent))
                    }
                    Button("En parler") { conversation.ouvrir() }
                        .buttonStyle(.hal(.verre))
                }
            }
        }
    }

    /// Connecté, le dernier message de HAL tel que le serveur l'a rendu ; sans
    /// serveur, celui des données fictives.
    private var dernierMot: String {
        guard foyer.connecte else { return foyer.dernierMotDeHAL }
        return conversation.messages.last { $0.auteur == .hal && !$0.texte.isEmpty }?.texte
            ?? "HAL n'a encore rien dit."
    }
}

/// Un ajustement sur une séance validée, en tête d'Aujourd'hui (PLN-18, WID-6).
/// La raison est écrite ; « En parler » ouvre HAL.
struct WidgetAjustement: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        let ajustement = foyer.ajustement ?? foyer.ajustementEnCours
        CoquilleWidget(.ajustement) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ajustement.titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                Text(ajustement.motif).texte(.corps).foregroundStyle(Palette.texteSecondaire).lineLimit(2)
                Spacer(minLength: 0)
                HStack {
                    Button("Accepter") { repondre(true) }.buttonStyle(.hal(.accent))
                    Button("Refuser") { repondre(false) }.buttonStyle(.hal(.verre))
                    Spacer()
                    Button("En parler") { conversation.ouvrir() }.buttonStyle(.hal(.verre))
                }
            }
        }
    }

    private func repondre(_ accepte: Bool) {
        Task {
            do {
                try await foyer.repondreAjustement(accepte: accepte)
                annoncer(accepte ? "Ajustement accepté" : "Ajustement refusé")
            } catch {
                annoncer((error as? ErreurAPI)?.message ?? "Réponse impossible")
            }
        }
    }
}

/// 3.21 : un ajustement proposé par HAL. Ce qui était prévu, ce que HAL
/// propose, la raison, puis « Accepter » ou « Refuser » (PLN-18, PLN-19).
struct EcranAjustement: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var ajustements: [AjustementDetaille]?
    @State private var envoi = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                BarrePoussee(titre: "Ajustement") { fermer() }
                if let ajustements {
                    if ajustements.isEmpty {
                        Text("Plus rien à trancher : HAL n'attend aucune réponse.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    ForEach(ajustements) { ajustement in
                        carte(ajustement)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
        .vuParHAL("Ajustement proposé")
        .task { await charger() }
    }

    private func carte(_ ajustement: AjustementDetaille) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Puce(TexteHAL.nature(ajustement.nature).capitalized, categorie: .menage)
                Spacer()
                if let debut = ajustement.debut {
                    Text("\(EnFrancais.jour(debut)) · \(EnFrancais.heure(debut))")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
            Text(ajustement.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
            if ajustement.nature == "retirer" {
                Text("HAL propose de retirer cette séance.").texte(.corps).foregroundStyle(Palette.textePrincipal)
            } else {
                HStack(spacing: 10) {
                    colonne("Avant", ajustement.avant, mise: false)
                    colonne("Après", ajustement.apres, mise: true)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Orbe(etat: .repos, taille: 20)
                Text(ajustement.motif).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Accepter") { Task { await repondre(ajustement, accepte: true) } }
                    .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                Button("Refuser") { Task { await repondre(ajustement, accepte: false) } }
                    .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
            }
            .disabled(envoi)
            Button("En parler à HAL") {
                conversation.demanderUnChangement(ElementJoint(
                    genre: .seance, idOccurrence: ajustement.idOccurrence, libelle: ajustement.titre))
            }
            .buttonStyle(.hal(.verre, pleineLargeur: true))
            Text("Sans réponse quand la séance commence : un allègement s'applique, un déplacement devient caduc.")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Espace.interne)
        .carte()
    }

    private func colonne(_ titre: String, _ lignes: (String, String), mise: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titre.uppercased()).texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
            Text(lignes.0).texte(.titre).foregroundStyle(Palette.textePrincipal)
            Text(lignes.1).texte(.legende).foregroundStyle(Palette.texteSecondaire)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous)
            .strokeBorder(mise ? Categorie.sport.couleur : Palette.verreBord, lineWidth: mise ? 1.5 : 0.5))
    }

    private func charger() async {
        ajustements = (try? await foyer.demander("GET", "ajustements")) ?? []
    }

    private func repondre(_ ajustement: AjustementDetaille, accepte: Bool) async {
        envoi = true
        defer { envoi = false }
        do {
            try await foyer.agir("POST", "ajustements/\(ajustement.idAjustement)/\(accepte ? "accepter" : "refuser")")
            annoncer(accepte ? "Ajustement accepté" : "Ajustement refusé")
            await charger()
            if ajustements?.isEmpty == true { fermer() }
        } catch {
            annoncer((error as? ErreurAPI)?.message ?? "Réponse impossible")
        }
    }
}

/// Un ajustement en attente, tel que `GET /ajustements` le rend.
struct AjustementDetaille: Codable, Identifiable, Sendable {
    struct Contenu: Codable, Sendable {
        var dureeMinutes: Int?
        var intensite: String?
        var typeSeance: String?
        var debut: Date?
    }

    let idAjustement: Int
    let idOccurrence: Int
    let nature: String
    let motif: String
    let contenu: Contenu?
    let debut: Date?
    let discipline: String?
    let typeSeance: String?
    let dureeMinutes: Int?
    let intensite: String?
    var id: Int { idAjustement }

    var titre: String {
        let type = typeSeance ?? ""
        return type.isEmpty || type == "libre" ? Discipline.nom(discipline) : type
    }

    /// « 45 min », « légère »
    var avant: (String, String) {
        (dureeMinutes.map { EnFrancais.duree(minutes: $0) } ?? "—",
         intensite.map(VueSeanceDuJour.intensite) ?? "")
    }

    var apres: (String, String) {
        if nature == "deplacer", let nouveau = contenu?.debut {
            return (EnFrancais.heure(nouveau), EnFrancais.jour(nouveau))
        }
        return ((contenu?.dureeMinutes ?? dureeMinutes).map { EnFrancais.duree(minutes: $0) } ?? "—",
                [contenu?.typeSeance.flatMap { $0 == typeSeance ? nil : $0 },
                 (contenu?.intensite ?? intensite).map(VueSeanceDuJour.intensite)]
                    .compactMap { $0 }.joined(separator: " · "))
    }
}
