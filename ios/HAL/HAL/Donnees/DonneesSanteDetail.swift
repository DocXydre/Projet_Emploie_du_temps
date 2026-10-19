import Foundation

// Ce que le serveur rend du détail de Santé (3.22 à 3.25). Tout est calculé
// en base (`detail_course`, `nuit_sante`, `forme_sante`) : l'appli affiche.

/// 3.22, 3.23 : `GET /appli/seances/{id}/course`.
struct CourseDetaillee: Decodable, Sendable {
    let type: String?
    let debut: Date
    let dureeSecondes: Int?
    let distanceM: Int?
    let deniveleM: Int?
    let energieKcal: Int?
    let fcMoyenne: Int?
    let fcMax: Int?
    let allureSKm: Int?
    let cadence: Int?
    let fcMaxConnue: Int?
    let etapes: [Etape]
    let kilometres: [Kilometre]
    let pauses: [Pause]
    let courbe: [PointCourbe]
    let zones: [Int]?
    let dynamique: Dynamique?
    let fcRecuperation: Int?
    let trace: [PointTrace]

    struct Etape: Decodable, Sendable, Identifiable {
        let rang: Int
        let nom: String
        let rapide: Bool
        let debutS: Int
        let dureeS: Int
        let distanceM: Double?
        let allureSKm: Int?
        let fc: Int?
        let prevu: Prevu?
        var id: Int { rang }
    }

    /// Ce que l'étape prévoyait, quand la séance a été envoyée à la montre (MON-1).
    struct Prevu: Decodable, Sendable {
        let dureeS: Int?
        let distanceM: Int?
        let objectifS: Int?
        let zone: Int?
        let allure: String?
    }

    struct Kilometre: Decodable, Sendable, Identifiable {
        let rang: Int
        let dureeS: Int
        let distanceM: Double?
        let fc: Int?
        var id: Int { rang }
    }

    struct Pause: Decodable, Sendable {
        let debutS: Int
        let dureeS: Int
    }

    struct PointCourbe: Decodable, Sendable {
        let t: Int
        let fc: Int?
        let allureSKm: Int?
    }

    struct Valeurs: Decodable, Sendable {
        let moyenne: Double?
        let fractions: Double?
    }

    struct Dynamique: Decodable, Sendable {
        let puissance: Valeurs?
        let cadence: Valeurs?
        let foulee: Valeurs?
        let contactSol: Valeurs?
        let oscillation: Valeurs?
    }

    struct PointTrace: Decodable, Sendable {
        let lat: Double
        let lon: Double
        let alt: Double?
        let t: Int
        let etape: Int?
        let rapide: Bool
    }

    /// Les fractions, dans l'ordre.
    var fractions: [Etape] { etapes.filter(\.rapide) }

    /// Ce que l'écran montre : une course avec un tracé ou des mesures.
    var detaillee: Bool { !trace.isEmpty || courbe.count > 1 }
}

/// 3.24 : `GET /appli/sante/nuit?jour=`.
struct NuitDetaillee: Decodable, Sendable {
    let jour: Date
    let coucher: Date
    let lever: Date
    let deLaMontre: Bool
    let phases: [Phase]
    let minutes: [String: Int]?
    let habitude: [String: Int]?
    let frequence: [PointNuit]?
    let fcPlusBasse: PlusBas?
    let mesures: Mesures?

    struct Phase: Decodable, Sendable {
        let phase: String
        let debut: Date
        let fin: Date
    }

    struct PointNuit: Decodable, Sendable {
        let minute: Int
        let bpm: Int?
    }

    struct PlusBas: Decodable, Sendable {
        let bpm: Int
        let quand: Date
    }

    struct Valeur: Decodable, Sendable {
        let valeur: Double?
        let plusBas: Double?
        let habitude: Double?
    }

    struct Mesures: Decodable, Sendable {
        let respiration: Valeur?
        let spo2: Valeur?
        let temperaturePoignet: Valeur?
        let vfc: Valeur?
    }
}

/// 3.25 : `GET /appli/sante/forme?jours=`.
struct FormeSante: Decodable, Sendable {
    let vo2max: [Point]
    let fcRecuperation: [Recuperation]
    let poids: [Pesee]
    let moyennes: Moyennes?
    let tendances: Tendances?

    struct Point: Decodable, Sendable {
        let jour: Date
        let valeur: Double
    }

    struct Recuperation: Decodable, Sendable {
        let quand: Date
        let valeur: Double
    }

    struct Pesee: Decodable, Sendable {
        let jour: Date
        let valeur: Double
        let source: String?
    }

    struct Moyennes: Decodable, Sendable {
        let energieJour: Double?
        let fcRepos: Double?
        let spo2: Double?
        let spo2PlusBas: Double?
        let respiration: Double?
    }

    struct Tendances: Decodable, Sendable {
        let fcRepos: Double?
    }
}
