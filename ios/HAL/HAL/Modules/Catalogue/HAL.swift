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
        widget: { _ in AnyView(WidgetAjustement()) }
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
