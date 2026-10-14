import Foundation

/// Le profil sportif (PRO-1) : ce que HAL sait de toi pour construire un plan.
/// Le poids n'y est pas : c'est une mesure.
struct ProfilSportif: Decodable, Equatable, Sendable {
    var dateNaissance: Date
    var sexe: String
    var tailleCm: Int
    var niveauMusculation: String
    var niveauCourse: String
    var momentPrefere: String? = "indifferent"
    var joursSansSport: [Int]? = []
    var accordComplements: Bool? = false
    var regime: String? = nil
}

/// Le corps de `PUT /profil` : la date en jour seul, pour ne pas glisser d'un
/// jour avec le fuseau.
struct EnvoiProfil: Encodable {
    let dateNaissance: String
    let sexe: String
    let tailleCm: Int
    let niveauMusculation: String
    let niveauCourse: String
    let momentPrefere: String
    let joursSansSport: [Int]
    let accordComplements: Bool
    let regime: String?
}

/// Une limitation qui dure (EXO-6), avec les exercices qu'elle interdit.
struct LimitationHAL: Codable, Hashable, Identifiable, Sendable {
    struct Interdit: Codable, Hashable, Sendable {
        let code: String
        let libelle: String?
        let motif: String?
    }

    let idLimitation: Int
    let libelle: String
    let zone: String?
    let cote: String?
    let description: String?
    let active: Bool?
    let interdits: [Interdit]?
    var id: Int { idLimitation }
}

/// Un lieu choisi pour une discipline, à son rang (LIE-1).
struct LieuChoisi: Codable, Hashable, Sendable {
    let discipline: String
    let rang: Int
    let idLieu: Int
    let libelle: String
}

/// Un lieu que le système connaît déjà (LIE-4).
struct LieuPossible: Codable, Hashable, Identifiable, Sendable {
    let idLieu: Int
    let code: String?
    let libelle: String
    var id: Int { idLieu }
}

/// Une pause de HAL (PAU-1).
struct PauseHAL: Codable, Hashable, Sendable {
    let depuis: Date?
    let jusquAu: Date?
    let motif: String?
}

/// `GET /appli/demarrage` : où en est le démarrage, et ce qui est déjà rempli.
struct EtatDemarrage: Decodable, Sendable {
    let manque: String?
    let coachActif: Bool
    let seancesMaxSemaine: Int?
    let etape: String?
    let brouillon: [String: String]
    let limitationsFaites: Bool
    let profil: ProfilSportif?
    let limitations: [LimitationHAL]
    let lieux: [LieuChoisi]
    let lieuxPossibles: [LieuPossible]
    let objectifs: [ObjectifDetaille]
    let plan: Bool
    let pause: PauseHAL?

    private enum CodingKeys: String, CodingKey {
        case manque, coachActif, seancesMaxSemaine, etape, brouillon, limitationsFaites, profil
        case limitations, lieux, lieuxPossibles, objectifs, plan, pause
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manque = try c.decodeIfPresent(String.self, forKey: .manque)
        coachActif = try c.decodeIfPresent(Bool.self, forKey: .coachActif) ?? false
        seancesMaxSemaine = try c.decodeIfPresent(Int.self, forKey: .seancesMaxSemaine)
        etape = try c.decodeIfPresent(String.self, forKey: .etape)
        // Le brouillon est à l'appli : des textes. Ce qui n'en est pas est ignoré.
        brouillon = (try? c.decodeIfPresent([String: String].self, forKey: .brouillon)) ?? [:]
        limitationsFaites = try c.decodeIfPresent(Bool.self, forKey: .limitationsFaites) ?? false
        profil = try? c.decodeIfPresent(ProfilSportif.self, forKey: .profil)
        limitations = (try? c.decodeIfPresent([LimitationHAL].self, forKey: .limitations)) ?? []
        lieux = (try? c.decodeIfPresent([LieuChoisi].self, forKey: .lieux)) ?? []
        lieuxPossibles = (try? c.decodeIfPresent([LieuPossible].self, forKey: .lieuxPossibles)) ?? []
        objectifs = (try? c.decodeIfPresent([ObjectifDetaille].self, forKey: .objectifs)) ?? []
        plan = try c.decodeIfPresent(Bool.self, forKey: .plan) ?? false
        pause = try? c.decodeIfPresent(PauseHAL.self, forKey: .pause)
    }
}

/// `GET /plan` : la trame et ses quatre semaines (OBJ-11, PLN-1).
struct PlanHAL: Decodable, Sendable {
    struct Plan: Decodable, Sendable {
        struct Semaine: Decodable, Hashable, Sendable {
            let lundi: Date
            let role: String?
            let intention: String?
            let validee: Date?

            private enum CodingKeys: String, CodingKey {
                case lundi, role, intention
                case validee = "valideeLe"
            }
        }

        let idPlan: Int
        let du: Date?
        let au: Date?
        let trame: String?
        let semaines: [Semaine]
    }

    let plan: Plan?
    let objectifPrincipal: ObjectifDetaille?
    let feuilleDeRoute: String?
    let manque: [String]?
}

/// Ce que rend `POST /objectifs` : l'objectif, et l'avis de HAL (OBJ-5).
struct ObjectifCree: Decodable, Sendable {
    struct Avis: Decodable, Sendable {
        let message: String?
        let planEnConstruction: Bool?
        let planEnAttenteDe: [String]?
    }

    let objectif: ObjectifDetaille?
    let coach: Avis?
}

/// La mémoire de HAL, étage par étage (MEM-1).
struct MemoireHAL: Decodable, Sendable {
    struct Etage: Decodable, Hashable, Sendable {
        let idMemoire: Int?
        let periode: Date?
        let texte: String?
        let auteur: String?
        let quand: Date?
        let longueur: Int?
        let limite: Int?
    }

    let globale: Etage?
    let troisMois: [Etage]?
    let mois: Etage?
    let semaine: Etage?
}

/// Une version d'un étage (MEM-2, MEM-5).
struct VersionMemoire: Decodable, Hashable, Identifiable, Sendable {
    let idMemoire: Int
    /// Les deux cents premiers caractères.
    let debut: String?
    let longueur: Int?
    let auteur: String?
    let quand: Date?
    var id: Int { idMemoire }
}

/// Les libellés des valeurs du profil.
enum LibellesHAL {
    static let niveaux = [("debutant", "Débutant"), ("intermediaire", "Intermédiaire"), ("avance", "Avancé")]
    static let moments = [("matin", "Le matin"), ("soir", "Le soir"), ("indifferent", "Peu importe")]
    static let sexes = [("homme", "Homme"), ("femme", "Femme")]
    static let jours = ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"]
    static let zones = [("épaule", "Épaule"), ("coude", "Coude"), ("avant-bras", "Avant-bras"),
                        ("poignet", "Poignet"), ("dos", "Dos"), ("hanche", "Hanche"),
                        ("genou", "Genou"), ("cheville", "Cheville"), ("autre", "Autre")]
    static let cotes = [("gauche", "Gauche"), ("droite", "Droite"), ("deux", "Les deux")]
    static let disciplines = [("musculation", "Musculation"), ("course", "Course"), ("cardio", "Cardio")]
    static let objectifs = [("force", "Prendre de la force", "dumbbell"),
                            ("physique", "Prendre du muscle", "figure.strengthtraining.traditional"),
                            ("endurance", "Endurance et santé", "heart"),
                            ("course", "Préparer une course", "figure.run")]
    static let distances = [(5000, "5 km"), (10000, "10 km"), (21097, "Semi"), (42195, "Marathon")]

    static func nom(_ valeur: String?, dans liste: [(String, String)]) -> String {
        liste.first { $0.0 == valeur }?.1 ?? (valeur ?? "")
    }

    /// « 50 », « 50 min », « 1h45 », « 52:30 » : des minutes, comme le bot les lit.
    static func minutes(_ texte: String) -> Double? {
        let t = texte.lowercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "minutes", with: "").replacingOccurrences(of: "min", with: "")
        let heures = t.split(separator: "h", omittingEmptySubsequences: false)
        if heures.count == 2, let h = Int(heures[0]) {
            return Double(h * 60 + (Int(heures[1]) ?? 0))
        }
        let morceaux = t.split(separator: ":").compactMap { Int($0) }
        if morceaux.count == 3 { return Double(morceaux[0] * 60 + morceaux[1]) + Double(morceaux[2]) / 60 }
        if morceaux.count == 2 { return Double(morceaux[0]) + Double(morceaux[1]) / 60 }
        return Int(t).map(Double.init)
    }

    static func duree(_ minutes: Double) -> String {
        let total = Int((minutes * 60).rounded())
        let (h, reste) = (total / 3600, total % 3600)
        let (m, s) = (reste / 60, reste % 60)
        if h > 0 { return "\(h)h\(String(format: "%02d", m))" }
        return "\(m) min" + (s > 0 ? " \(String(format: "%02d", s))" : "")
    }
}
