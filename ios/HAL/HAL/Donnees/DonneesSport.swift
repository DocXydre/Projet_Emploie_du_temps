import Foundation

/// Ce que rend `GET /appli/sport`, tel quel. Gardé sur le téléphone : la séance
/// du jour, ses exercices et leurs alternatives sont là même sans réseau (SAI-10).
struct EtatSport: Codable, Sendable {
    struct Semaine: Codable, Sendable {
        let faites: Int
        let prevues: Int
        let prochaine: Prochaine?
    }

    struct Prochaine: Codable, Sendable {
        let idOccurrence: Int
        let debut: Date
        let discipline: String?
        let typeSeance: String?
        let dureeMinutes: Int?
    }

    struct JourDeForme: Codable, Sendable {
        let jour: Date
        let pas: Int?
        let fcRepos: Int?
        let vfcMs: Double?
        let sommeilMinutes: Int?
    }

    struct ObjectifAPI: Codable, Sendable {
        let idObjectif: Int
        let libelle: String
        let echeance: Date?
        let dateCreation: Date?
        let joursRestants: Int?
    }

    struct FenetreMesure: Codable, Sendable {
        let idFenetre: Int
        let typeMesure: String
        let du: Date
        let au: Date
        let consigne: String?
        /// La séance de test à laquelle HAL a rattaché la fenêtre (MES-6).
        var jourSeance: Date? = nil

        /// MES-1 : une fenêtre ne se montre qu'une fois commencée, et pas avant
        /// le jour de sa séance de test.
        var commencee: Bool {
            let aujourdhui = Calendar.current.startOfDay(for: .now)
            return du <= aujourdhui && (jourSeance.map { $0 <= aujourdhui } ?? true)
        }
    }

    struct AjustementAPI: Codable, Sendable {
        let idAjustement: Int
        let idOccurrence: Int
        let nature: String
        let motif: String
        let jour: Date?
        let typeSeance: String?
        let discipline: String?
    }

    struct PauseAPI: Codable, Sendable {
        let fin: Date?
        let motif: String?
    }

    let coachActif: Bool
    let semaine: Semaine
    let seancesDuJour: [DetailSeance]
    let forme: [JourDeForme]
    let objectif: ObjectifAPI?
    let mesures: [FenetreMesure]
    let ajustements: [AjustementAPI]
    let pause: PauseAPI?
    let semaineAValider: SemaineAValider?
    let invitations: [InvitationAPI]?
    /// DEM-1 : le premier bloc du démarrage de HAL qui manque, ou rien.
    var demarrage: String? = nil

    struct SemaineAValider: Codable, Sendable {
        let lundi: Date
        let seances: Int
    }

    /// SPT-31 : l'autre propose une séance à deux.
    struct InvitationAPI: Codable, Hashable, Identifiable, Sendable {
        let idInvitation: Int
        let qui: String
        let lieu: String?
        let debut: Date
        var id: Int { idInvitation }
    }
}

/// 3.2 : une semaine de sport, à valider d'un geste.
struct SemaineDeSport: Codable, Sendable {
    struct SeanceDeLaSemaine: Codable, Hashable, Identifiable, Sendable {
        let idOccurrence: Int
        let jour: Date
        let debut: Date?
        let discipline: String?
        let typeSeance: String?
        let intensite: String?
        let dureeMinutes: Int?
        let situation: String?
        let lieu: String?
        let consigne: String?
        let exercices: Int?
        var id: Int { idOccurrence }
    }

    let lundi: Date
    let role: String?
    let intention: String?
    let validee: Date?
    let aValider: Bool
    let seances: [SeanceDeLaSemaine]
    /// Chapitre 8.1 : effort noté multiplié par la durée. Absente sans bilan.
    var charge: Charge? = nil

    struct Charge: Codable, Sendable {
        let chargeSeptJours: Double?
        let chargeQuatreSemaines: Double?
        let rapport: Double?
        let seancesSeptJours: Int?
        let seancesSansBilan: Int?
    }

    private enum CodingKeys: String, CodingKey {
        case lundi, role, intention, aValider, seances, charge
        case validee = "valideeLe"
    }
}

/// 3.1, 3.19 : une mesure saisie, dans la fenêtre de HAL ou hors fenêtre (MES-4).
struct MesureSaisie: Codable, Hashable, Identifiable, Sendable {
    let idMesure: Int
    let typeMesure: String
    let valeur: Double
    let unite: String
    let cote: String?
    let dateMesure: Date
    var id: Int { idMesure }
}

/// 3.16 : les journées de Santé reçues par le serveur, et les séances de la montre.
struct HistoriqueSante: Codable, Sendable {
    struct Activite: Codable, Hashable, Sendable {
        let type: String?
        let discipline: String?
        let debut: Date
        let dureeSecondes: Int?
        let distanceM: Int?
        let fcMoyenne: Int?
        let fcMax: Int?
        let allureSKm: Int?
        let energieKcal: Int?
    }

    let jours: [EtatSport.JourDeForme]
    let seances: [Activite]
}

/// 3.17 : une semaine d'un exercice.
struct SemaineDExercice: Codable, Hashable, Sendable {
    let code: String
    let libelle: String
    let lundi: Date
    let meilleureCharge: Double?
    let meilleuresRepetitions: Int?
    let volume: Double?
    let series: Int?
}

/// 3.18 : un objectif, avec l'avis de HAL et sa feuille de route.
struct ObjectifDetaille: Codable, Hashable, Identifiable, Sendable {
    let idObjectif: Int
    let type: String?
    let libelle: String
    let echeance: Date?
    let principal: Bool
    let statut: String
    let avis: String?
    let avisDetail: String?
    let feuilleDeRoute: String?
    var id: Int { idObjectif }
}

/// Une séance telle que le serveur la décrit : ce qui est prévu, avec les
/// alternatives permises, et ce qui est déjà saisi.
struct DetailSeance: Codable, Hashable, Sendable {
    struct Seance: Codable, Hashable, Sendable {
        let idOccurrence: Int
        let jour: Date?
        let debut: Date?
        let lieu: String?
        let situation: String?
        let libre: Bool?
        let discipline: String?
        let typeSeance: String?
        let intensite: String?
        let dureeMinutes: Int?
        let consigne: String?
        let effort: Int?
        let commentaire: String?
        let avisLibre: String?
    }

    /// SAN-2 : ce que la montre a enregistré pour cette séance.
    struct Montre: Codable, Hashable, Sendable {
        let type: String?
        let dureeSecondes: Int?
        let distanceM: Int?
        let deniveleM: Int?
        let energieKcal: Int?
        let fcMoyenne: Int?
        let fcMax: Int?
        let allureSKm: Int?
        let cadence: Int?
    }

    let seance: Seance
    let prevu: [LignePrevue]
    let saisi: [SerieServeur]
    let montre: [Montre]?

    /// Faite, pas faite, remplacée ou retirée : il n'y a plus rien à lancer.
    var close: Bool {
        ["faite", "pas_faite", "remplacee", "retiree"].contains(seance.situation ?? "")
    }

    var titre: String {
        let type = seance.typeSeance ?? ""
        if type.isEmpty || type == "libre" { return Discipline.nom(seance.discipline) }
        return type.prefix(1).uppercased() + type.dropFirst()
    }
}

/// Une ligne prévue par HAL dans une séance.
struct LignePrevue: Codable, Hashable, Identifiable, Sendable {
    struct Alternative: Codable, Hashable, Sendable {
        let idExercice: Int
        let code: String
        let libelle: String
    }

    let idSeanceExercice: Int
    let rang: Int?
    let idExercice: Int
    let code: String
    let libelle: String
    let mesure: String?
    let series: Int?
    let repetitionsMin: Int?
    let repetitionsMax: Int?
    let chargeKg: Double?
    let dureeSecondes: Int?
    let distanceM: Int?
    let reposSecondes: Int?
    let consigne: String?
    let alternatives: [Alternative]?

    var id: Int { idSeanceExercice }

    /// « 4 × 8 à 10 · 40 kg ».
    var enClair: String {
        var morceaux: [String] = []
        if let series, let repetitionsMin, let repetitionsMax {
            morceaux.append(repetitionsMin == repetitionsMax
                            ? "\(series) × \(repetitionsMin)" : "\(series) × \(repetitionsMin) à \(repetitionsMax)")
        } else if let series {
            morceaux.append("\(series) séries")
        }
        if let chargeKg { morceaux.append(Poids.texte(chargeKg)) }
        if let dureeSecondes { morceaux.append("\(dureeSecondes) s") }
        if let distanceM { morceaux.append("\(distanceM) m") }
        return morceaux.joined(separator: " · ")
    }
}

/// Une série déjà sur le serveur.
struct SerieServeur: Codable, Hashable, Sendable {
    let idSerie: Int
    let code: String
    let libelle: String?
    let numero: Int?
    let chargeKg: Double?
    let repetitions: Int?
    let dureeSecondes: Int?
    let distanceM: Int?
    let saisieLe: Date?
    let idSeanceExercice: Int?
}

/// Un exercice du catalogue (`GET /exercices`).
struct ExerciceCatalogue: Codable, Hashable, Identifiable, Sendable {
    let idExercice: Int
    let code: String
    let libelle: String
    let groupePrincipal: String?
    let materiel: String?
    let mesure: String?
    /// SEC-1 : une limitation l'interdit. Il est montré grisé, jamais proposé.
    let interdit: Bool?
    let derniereSaisie: Date?

    var id: Int { idExercice }
}

enum Discipline {
    static func nom(_ code: String?) -> String {
        switch code {
        case "musculation": "Musculation"
        case "course": "Course"
        case "natation": "Natation"
        case "velo": "Vélo"
        case "cardio": "Cardio"
        case let autre?: autre.prefix(1).uppercased() + autre.dropFirst()
        case nil: "Séance"
        }
    }
}

enum Poids {
    /// « 42,5 kg », « 40 kg ».
    static func texte(_ valeur: Double) -> String {
        let entier = valeur.truncatingRemainder(dividingBy: 1) == 0
        let nombre = entier ? String(Int(valeur))
            : String(format: "%.1f", valeur).replacingOccurrences(of: ".", with: ",")
        return "\(nombre) kg"
    }

    /// SAI-17 : arrondi au palier de 2,5 kg.
    static func palier(_ valeur: Double) -> Double {
        (valeur / 2.5).rounded() * 2.5
    }
}

/// Les mesures que HAL peut demander (MES), avec leur unité.
enum TypeMesure {
    /// Les types que le serveur accepte, dans l'ordre de l'écran Mesures.
    static let tous = ["poids", "tour_taille", "tour_poitrine", "tour_bras", "tour_avant_bras",
                       "tour_cuisse", "test_course", "test_force"]

    /// Le nom d'une mesure dans une liste : « Poids », pas « Pèse-toi ».
    static func libelle(_ type: String) -> String {
        type == "poids" ? "Poids" : nom(type)
    }

    /// Une valeur lisible : 13 min 05 pour un test de course, 70,8 kg pour un poids.
    static func enClair(_ valeur: Double, unite: String) -> String {
        switch unite {
        case "s":
            let total = Int(valeur.rounded())
            return "\(total / 60) min \(String(format: "%02d", total % 60))"
        case "reps":
            return "\(Int(valeur.rounded())) reps"
        default:
            let nombre = valeur.formatted(.number.precision(.fractionLength(0...1))
                .locale(Locale(identifier: "fr_FR")))
            return "\(nombre) \(unite)"
        }
    }

    static func nom(_ type: String) -> String {
        switch type {
        case "poids": "Pèse-toi"
        case "tour_taille": "Tour de taille"
        case "tour_bras": "Tour de bras"
        case "tour_avant_bras": "Tour d'avant-bras"
        case "tour_cuisse": "Tour de cuisse"
        case "tour_poitrine": "Tour de poitrine"
        case "test_course": "Test de course"
        case "test_force": "Test de force"
        default: type
        }
    }

    static func unite(_ type: String) -> String {
        switch type {
        case "poids": "kg"
        // Un test de course se note au temps, un test de force aux répétitions,
        // comme le bot le faisait.
        case "test_course": "s"
        case "test_force": "reps"
        default: "cm"
        }
    }
}

extension DetailSeance: Identifiable {
    var id: Int { seance.idOccurrence }
}
