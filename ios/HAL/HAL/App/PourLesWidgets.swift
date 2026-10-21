import Foundation
import WidgetKit

/// IOS-1, IOS-2 : après chaque chargement, l'appli garde pour ses widgets ce
/// qu'ils montrent, et leur demande de se redessiner. Les widgets n'appellent
/// jamais le serveur eux-mêmes.
extension Foyer {
    func publierPourLesWidgets() {
        guard connecte else { return }
        let debutDuJour = Calendar.current.startOfDay(for: .now)
        let finDuJour = Calendar.current.date(byAdding: .day, value: 1, to: debutDuJour) ?? .now
        let journee = evenementsDuJour
            .filter { !$0.journeeEntiere && $0.debut >= debutDuJour && $0.debut < finDuJour }
            .map { Instantane.Moment(debut: $0.debut, fin: $0.fin, titre: $0.titre, lieu: $0.lieu,
                                     categorie: $0.categorie.rawValue) }
        let instantane = Instantane(
            misAJour: .now,
            sport: Instantane.Sport(faites: semaine.faites, prevues: semaine.prevues,
                                    prochaine: semaine.prochaine),
            // MON-8 : sans montre, pas de FC de repos sur l'écran d'accueil non plus.
            forme: Instantane.Forme(sommeilMinutes: forme.sommeilMinutes,
                                    fcRepos: aUneMontre ? forme.fcRepos : nil,
                                    pas: forme.pas),
            journee: journee,
            halADire: orbeADire)
        Partage.ecrire(instantane)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
