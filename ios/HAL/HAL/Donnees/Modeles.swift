import SwiftUI

/// Ce que l'appli affiche. `Foyer` les remplit depuis l'API, ou depuis `Apercu`
/// en démonstration.

struct Membre: Identifiable, Hashable {
    let id: Int
    let nom: String
    let estAdministrateur: Bool
    /// Ce qui désigne le membre pour l'API : « lorette ».
    var pseudo: String = ""
}

struct Evenement: Identifiable, Hashable {
    let id = UUID()
    let debut: Date
    var fin: Date? = nil
    let titre: String
    var lieu: String? = nil
    let categorie: Categorie
    /// Une tâche sans heure tient la journée : elle ne compte pas comme « maintenant ».
    var journeeEntiere: Bool = false

    /// L'heure de la ligne : « 12:45 », ou « Jour » pour ce qui tient la journée.
    var heure: String {
        journeeEntiere ? "Jour" : debut.formatted(date: .omitted, time: .shortened)
    }
}

struct Tache: Identifiable, Hashable {
    let id: Int
    let titre: String
    /// Le membre à qui elle revient.
    let pourQui: Membre
    let categorie: Categorie
    var faite: Bool
    /// Le nombre de reports subis (EXE-4).
    var reports: Int = 0
    /// En retard selon le serveur : reportée, ou sa fenêtre est passée (EXE-4).
    var enRetard: Bool = false
    /// La fin de sa fenêtre, pour dire depuis quand elle traîne.
    var fin: Date?
    /// Son heure prévue, sauf si elle tient la journée.
    var debut: Date?
    var journeeEntiere = false
    var reportable: Bool = true
    /// La tâche dont elle est une fois, pour ouvrir son détail (4.2).
    var idTache: Int? = nil
    /// TAC-25 : son type, qui donne sa couleur et son icône.
    var type: TypeTache? = nil

    /// La couleur du type, sinon celle de la famille.
    var couleur: Color { type.flatMap { Categorie.couleurDuType($0.couleur) } ?? categorie.couleur }
}

/// Une absence d'un membre : ses tâches passent aux autres (ABS).
struct Absence: Identifiable, Hashable {
    let id: Int
    let pour: Membre
    let debut: Date
    let fin: Date
    let lieu: String?
    /// « trajet » quand elle vient d'un billet SNCF, « manuelle » sinon.
    var origine: String? = nil

    var enCours: Bool { debut <= .now && fin > .now }
}

/// Un mode allégé en cours ou à venir (PLA-16).
struct Allegement: Hashable {
    let pour: Membre
    let debut: Date
    let fin: Date
}

/// Un week-end repéré, en attente d'un oui ou d'un non (PRO).
struct Proposition: Identifiable, Hashable {
    let id: Int
    let debut: Date
    let fin: Date
    let lieu: String
}

/// Ce que l'administrateur du foyer permet sur les tâches (FOY-6).
struct Droits: Hashable {
    let ajouter: Bool
    let modifier: Bool
}

struct SemaineSport: Hashable {
    let faites: Int
    let prevues: Int
    /// « Jeu. 18:30 · Course ».
    let prochaine: String?
}

/// La forme du jour, telle que Santé l'envoie. Une valeur absente reste `nil` (SAN-5).
struct Forme: Hashable {
    var sommeilMinutes: Int?
    var fcRepos: Int?
    var vfc: Int?
    var pas: Int?
    var tendanceFC: String?
}

struct SeanceDuJour: Hashable {
    let titre: String
    let heure: String
    let duree: String
    let exercices: [String]
    let consigne: String
}

struct Conflit: Identifiable, Hashable {
    struct Cours: Hashable {
        let titre: String
        let horaire: String
        let salle: String
    }

    let id: Int
    let jour: String
    let premier: Cours
    let second: Cours
}

struct Ajustement: Identifiable, Hashable {
    let id: Int
    let titre: String
    let motif: String
}

struct MesureDemandee: Hashable {
    let titre: String
    let consigne: String
    let jusquA: String
    /// La fenêtre ouverte par HAL, et le type de mesure (MES).
    var id: Int = 0
    var type: String = "poids"
}

struct Objectif: Hashable {
    let titre: String
    let joursRestants: Int
    /// De 0 à 1.
    let avancee: Double
}

/// Les tâches du type Chat, quels que soient leurs noms : la prochaine fois de chacune.
struct EtatChat: Hashable {
    struct Soin: Hashable {
        let titre: String
        let quand: String
    }
    var soins: [Soin] = []
}

