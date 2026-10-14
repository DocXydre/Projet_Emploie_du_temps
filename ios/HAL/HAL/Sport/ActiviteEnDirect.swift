import ActivityKit
import Foundation

/// La Live Activity de la séance en cours (IOS-3) : elle naît au lancement, suit
/// chaque série et chaque repos, et s'efface à la fin de la séance.
@MainActor
final class ActiviteEnDirect {
    private var activite: Activity<AttributsSeance>?

    init() {
        // Une séance reprise après un redémarrage de l'appli retrouve son activité.
        activite = Activity<AttributsSeance>.activities.first
    }

    func publier(titre: String, debut: Date, etat: AttributsSeance.ContentState?) {
        guard let etat else {
            terminer()
            return
        }
        let contenu = ActivityContent(state: etat, staleDate: nil)
        if let activite {
            Task { await activite.update(contenu) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activite = try? Activity.request(attributes: AttributsSeance(titre: titre, debut: debut),
                                         content: contenu)
    }

    func terminer() {
        guard let activite else { return }
        self.activite = nil
        Task { await activite.end(nil, dismissalPolicy: .immediate) }
    }
}
