import Foundation

/// Ce que l'appli affiche. Ces types suivent ce que l'API rendra ; pour l'instant
/// ils sont remplis par `Apercu`, avec des données fictives.

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

/// Une parole de la conversation avec HAL.
struct Message: Identifiable, Hashable {
    enum Auteur: Hashable { case moi, hal }

    let id = UUID()
    let auteur: Auteur
    let texte: String
}
