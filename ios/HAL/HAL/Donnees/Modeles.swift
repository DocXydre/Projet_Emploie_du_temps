import Foundation

/// Ce que l'appli affiche. `Foyer` les remplit depuis l'API, ou depuis `Apercu`
/// en démonstration.

struct Membre: Identifiable, Hashable {
    let id: Int
    let nom: String
    let estAdministrateur: Bool
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
}

struct Tache: Identifiable, Hashable {
    let id: Int
    let titre: String
    /// Le membre à qui elle revient.
    let pourQui: Membre
    let categorie: Categorie
    var faite: Bool
    /// Le nombre de reports subis : au-delà de zéro, elle est en retard (EXE-4).
    var reports: Int = 0
    /// Le code de la tâche récurrente, « ASPIRATEUR ».
    var code: String = ""
    var reportable: Bool = true
}

/// Une absence d'un membre : ses tâches passent aux autres (ABS).
struct Absence: Identifiable, Hashable {
    let id: Int
    let pour: Membre
    let debut: Date
    let fin: Date
    let lieu: String?
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

struct EtatChat: Hashable {
    let litiere: String
    let eau: String
    let fontaine: String
}

