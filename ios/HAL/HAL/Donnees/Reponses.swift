import Foundation

/// Ce que rend `GET /appli/aujourdhui`, tel quel. `Foyer` le traduit ensuite en
/// modèles d'affichage. Gardé sur le téléphone, il sert hors réseau (APP-3).
struct EtatDuJour: Codable {
    struct MembreAPI: Codable {
        let id: Int
        let pseudo: String
        let nom: String
        let administrateur: Bool
        let moi: Bool
    }

    struct EvenementAPI: Codable {
        let nature: String
        let id: Int
        let titre: String
        let debut: Date
        let fin: Date?
        let journeeEntiere: Bool?
        let lieu: String?
        let statut: String?
        let categorie: String
    }

    struct TacheAPI: Codable {
        let id: Int
        let idTache: Int
        let code: String
        let titre: String
        let pour: Int?
        let categorie: String
        let statut: String
        let faite: Bool
        let reports: Int?
        let enRetard: Bool?
        let debut: Date?
        let fin: Date?
        let journeeEntiere: Bool?
        let dureeMinutes: Int?
        let actionsPossibles: [String]?
    }

    struct CoursAPI: Codable, Hashable {
        let titre: String
        let debut: Date
        let fin: Date
        let lieu: String?
    }

    struct ConflitAPI: Codable {
        let id: Int
        let jour: Date
        let existante: CoursAPI
        let nouvelle: CoursAPI
    }

    struct AbsenceAPI: Codable, Hashable {
        let id: Int
        let pour: Int
        let debut: Date
        let fin: Date
        let lieu: String?
        let origine: String?
    }

    struct AllegementAPI: Codable, Hashable {
        let pour: Int
        let debut: Date
        let fin: Date
    }

    struct ChatAPI: Codable {
        let litiere: Date?
        let eau: Date?
        let fontaine: Date?
    }

    struct EquilibreAPI: Codable {
        let pour: Int
        let minutes: Int
    }

    struct PropositionAPI: Codable, Hashable {
        let id: Int
        let debut: Date
        let fin: Date
        let lieu: String?
    }

    struct DroitsAPI: Codable {
        let ajouter: Bool
        let modifier: Bool
    }

    /// Ce qui manque à un compte neuf (8.6 à 8.8).
    struct DepartAPI: Codable {
        /// Mes calendriers suivis, lien donné.
        let calendriers: Int
        /// Les tâches actives du foyer, hors sport.
        let taches: Int
    }

    let jour: Date
    let membres: [MembreAPI]
    let evenements: [EvenementAPI]
    let taches: [TacheAPI]
    let conflit: ConflitAPI?
    let absences: [AbsenceAPI]
    let allegements: [AllegementAPI]
    let chat: ChatAPI?
    let equilibre: [EquilibreAPI]
    let propositions: [PropositionAPI]
    let orbe: Bool
    let droits: DroitsAPI?
    /// Absent d'une réponse gardée avant le lot 8.
    let depart: DepartAPI?
}

/// Une tâche récurrente du foyer, telle que `GET /taches` la rend.
struct TacheRecurrente: Codable, Identifiable, Hashable {
    let idTache: Int
    let code: String
    let libelle: String
    let categorie: String
    var id: Int { idTache }
}

/// Un train proposé par `POST /trajets/aller` ou `/trajets/retour`.
struct Train: Codable, Identifiable, Hashable {
    let idTrajet: Int
    let depart: Date
    let arrivee: Date
    let correspondances: Int?
    let resume: String?
    var id: Int { idTrajet }
}

struct ChoixDeTrains: Codable {
    let trajets: [Train]
}

/// L'état du mode allégé, avec la phrase du serveur.
struct EtatAllegement: Codable {
    let enCours: Bool
    let fin: Date?
    let texte: String
}
