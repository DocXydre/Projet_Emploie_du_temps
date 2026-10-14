import Foundation
import Observation

/// Où va l'appli, d'où qu'on le demande : l'onglet affiché, une feuille ouverte
/// par-dessus (une carte de départ, un widget vide), un lien d'invitation reçu.
@MainActor
@Observable
final class Aiguillage {
    /// Ce qui s'ouvre en feuille au-dessus de n'importe quel onglet.
    enum Feuille: String, Identifiable {
        /// Ajouter un calendrier à suivre (5.4).
        case ajouterCalendrier
        /// Ajouter une tâche au foyer (4.3).
        case ajouterTache
        /// Inviter quelqu'un dans le foyer (5.16).
        case inviter

        var id: String { rawValue }
    }

    var onglet: Onglet = .aujourdhui
    var feuille: Feuille?
    /// Un lien d'invitation ouvert depuis la page du serveur (5.18).
    var invitation: InvitationOuverte?
    /// Un lien d'invitation ouvert alors qu'un compte est déjà connecté.
    var invitationRefusee = false

    /// `hal://rejoindre?serveur=https%3A%2F%2F…&code=ABCDE-FGHJK`. Rend vrai si le
    /// lien est une invitation.
    @discardableResult
    func ouvrir(_ url: URL) -> Bool {
        guard url.scheme == "hal", url.host() == "rejoindre",
              let morceaux = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let valeur = { (nom: String) in morceaux.queryItems?.first { $0.name == nom }?.value }
        guard let code = valeur("code"), !code.isEmpty else { return false }
        invitation = InvitationOuverte(serveur: valeur("serveur"), code: code)
        return true
    }
}

/// Le code et le serveur d'une invitation, tels que le lien les donne (FOY-3).
struct InvitationOuverte: Equatable {
    let serveur: String?
    let code: String
}
