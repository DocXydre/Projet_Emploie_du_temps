import Foundation
import Observation

/// Les états qu'on peut forcer pour essayer l'appli sans serveur
/// (Réglages, Essais). Ils disparaîtront quand l'API sera branchée.
struct Essais: Hashable {
    var horsReseau = false
    var modeAllege = false
    var absence = false
    var pause = false
    var conflit = true
    var ajustement = false
    var mesure = false
    var jourDeMuscu = false
    var foyerVide = false
}

/// Les données du foyer que lisent les modules. Une seule source pour toute
/// l'appli : les widgets ne calculent rien, ils affichent (WID-8).
@MainActor
@Observable
final class Foyer {
    var essais = Essais()

    private(set) var moi: Membre
    private(set) var autre: Membre?
    private(set) var evenements: [Evenement]
    var taches: [Tache]
    private(set) var semaine: SemaineSport
    private(set) var forme: Forme
    private(set) var frequenceDuJour: [PointSerie]
    private(set) var seance: SeanceDuJour
    private(set) var conflitEnCours: Conflit
    private(set) var ajustementEnCours: Ajustement
    private(set) var mesureEnCours: MesureDemandee
    private(set) var objectif: Objectif
    private(set) var chat: EtatChat
    private(set) var dernierMotDeHAL: String

    init(apercu: Apercu = Apercu()) {
        moi = apercu.moi
        autre = apercu.autre
        evenements = apercu.evenements
        taches = apercu.taches
        semaine = apercu.semaine
        forme = apercu.forme
        frequenceDuJour = apercu.frequence
        seance = apercu.seance
        conflitEnCours = apercu.conflit
        ajustementEnCours = apercu.ajustement
        mesureEnCours = apercu.mesure
        objectif = apercu.objectif
        chat = apercu.chat
        dernierMotDeHAL = apercu.dernierMotDeHAL
    }

    // MARK: Ce que les widgets lisent

    var evenementsDuJour: [Evenement] { essais.foyerVide ? [] : evenements }
    var tachesDuJour: [Tache] { essais.foyerVide ? [] : taches }
    var tachesEnRetard: [Tache] { tachesDuJour.filter { $0.reports > 0 && !$0.faite } }

    /// L'événement en cours ou le prochain.
    var maintenant: Evenement? {
        let date = Date()
        return evenementsDuJour.first { ($0.fin ?? $0.debut) > date }
    }

    var ensuite: Evenement? {
        guard let maintenant, let rang = evenementsDuJour.firstIndex(of: maintenant),
              rang + 1 < evenementsDuJour.count else { return nil }
        return evenementsDuJour[rang + 1]
    }

    var conflit: Conflit? { essais.conflit && !essais.foyerVide ? conflitEnCours : nil }
    var ajustement: Ajustement? { essais.ajustement ? ajustementEnCours : nil }
    var mesureDemandee: MesureDemandee? { essais.mesure ? mesureEnCours : nil }
    var seanceAPrevoir: SeanceDuJour? { essais.jourDeMuscu ? seance : nil }

    /// La part des tâches partagées faite par chacun, de 0 à 1, pour l'équilibre.
    var partDeMoi: Double {
        let faites = tachesDuJour.filter(\.faite)
        guard !faites.isEmpty else { return 0.5 }
        return Double(faites.filter { $0.pourQui == moi }.count) / Double(faites.count)
    }

    // MARK: Ce que l'utilisateur fait

    /// Coche ou décoche une tâche, même celle de l'autre (EXE-14). L'envoi passe par
    /// la file d'attente, qui le garde si le réseau manque (APP-3).
    func basculer(_ tache: Tache, file: FileAttente) {
        guard let rang = taches.firstIndex(where: { $0.id == tache.id }) else { return }
        taches[rang].faite.toggle()
        let chemin = taches[rang].faite
            ? "/occurrences/\(tache.id)/valider"
            : "/occurrences/\(tache.id)/annuler"
        file.ajouter(methode: "POST", chemin: chemin)
    }

    func choisir(_ cours: Conflit.Cours) {
        essais.conflit = false
    }

    func repondreAjustement(accepte: Bool) {
        essais.ajustement = false
    }
}
