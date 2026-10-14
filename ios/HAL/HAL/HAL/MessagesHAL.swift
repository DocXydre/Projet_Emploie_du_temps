import Foundation

/// Qui parle dans le panneau.
enum AuteurHAL: String, Codable, Sendable {
    case moi, hal, systeme
}

/// Un bouton d'un élément, tel que le serveur le décrit (COA-17) : l'appli n'a
/// aucune adresse en dur pour les boutons d'un message.
struct ActionHAL: Codable, Hashable, Sendable {
    let libelle: String
    let methode: String
    let route: String

    /// La route sans sa barre de tête : le client la pose après l'adresse du serveur.
    var chemin: String { route.hasPrefix("/") ? String(route.dropFirst()) : route }
}

/// Une semaine d'un plan, dans l'élément « plan ».
struct SemaineDuPlan: Codable, Hashable, Sendable {
    let lundi: String?
    let role: String?
}

/// Un élément d'une réponse de HAL : ce qu'il a vraiment écrit en base (COA-18).
/// Tout est facultatif : un élément mal formé est sauté, il ne casse pas le message.
struct ElementHAL: Codable, Hashable, Identifiable, Sendable {
    let type: String
    var idOccurrence: Int?
    var idAjustement: Int?
    var idFenetre: Int?
    var idObjectif: Int?
    var idPlan: Int?
    var jour: String?
    var debut: String?
    var du: String?
    var au: String?
    var lundi: String?
    var discipline: String?
    var typeSeance: String?
    var lieu: String?
    var dureeMinutes: Int?
    var intensite: String?
    var esquisse: Bool?
    var nature: String?
    var motif: String?
    var typeMesure: String?
    var consigne: String?
    var libelle: String?
    var avis: String?
    var detail: String?
    var seances: Int?
    var semaines: [SemaineDuPlan]?
    var actions: [ActionHAL]?
    /// Ce que l'élément est devenu depuis : « en_attente » tant que ses boutons
    /// servent, sinon accepte, refuse, validee, retiree…
    var etat: String?

    /// L'élément est réglé : ses boutons ne servent plus.
    var regle: String? {
        guard let etat, etat != "en_attente" else { return nil }
        switch etat {
        case "accepte": return "Accepté"
        case "refuse": return "Refusé"
        case "applique": return "Appliqué"
        case "validee": return "Validée"
        case "retiree": return "Retirée"
        case "faite": return "Faite"
        case "pas_faite": return "Pas faite"
        case "remplacee": return "Remplacée"
        case "supprimee": return "Supprimée"
        case "reportee": return "Repoussée"
        case "expiree": return "Expirée"
        case "posee_a_la_main": return "Posée à la main"
        default: return "Plus d'actualité"
        }
    }

    var id: String {
        "\(type)-\(idOccurrence ?? idAjustement ?? idFenetre ?? idObjectif ?? idPlan ?? 0)-\(lundi ?? "")"
    }
}

/// Un message du panneau : le sien, une réponse de HAL, ou le message fixe du
/// système quand HAL ne répond pas (COA-12).
struct MessageHAL: Identifiable, Hashable, Sendable {
    var id: String
    var auteur: AuteurHAL
    var texte: String
    var elements: [ElementHAL] = []
    var quand: Date? = nil
    var moment: String? = nil
    /// Un message parti de l'appli qui attend encore sa réponse (ORB-8).
    var enAttente = false
}

extension MessageHAL: Decodable {
    private enum CodingKeys: String, CodingKey {
        case idEchange, auteur, message, elements, quand, moment
    }

    /// Un élément qu'on ne sait pas lire est sauté, pas le message entier.
    private struct Peut: Decodable {
        let element: ElementHAL?
        init(from decoder: Decoder) throws { element = try? ElementHAL(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let numero = try c.decodeIfPresent(Int.self, forKey: .idEchange)
        id = numero.map { "e\($0)" } ?? UUID().uuidString
        switch try c.decodeIfPresent(String.self, forKey: .auteur) {
        case "utilisateur": auteur = .moi
        case "coach": auteur = .hal
        default: auteur = .systeme
        }
        texte = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        elements = (try? c.decodeIfPresent([Peut].self, forKey: .elements))?.compactMap(\.element) ?? []
        quand = try? c.decodeIfPresent(Date.self, forKey: .quand)
        moment = try c.decodeIfPresent(String.self, forKey: .moment)
    }
}

/// Ce qui est joint au message : la séance ou la semaine sur laquelle on demande
/// un changement (COA-32, ORB-10).
struct ElementJoint: Codable, Equatable, Sendable {
    enum Genre: String, Codable, Sendable { case seance, semaine }
    var genre: Genre
    var idOccurrence: Int? = nil
    var lundi: Date? = nil
    var libelle: String
}

/// Un message gardé tant que HAL n'a pas répondu : rien n'est perdu (ORB-8).
struct DemandeEnAttente: Codable, Equatable, Sendable {
    var texte: String
    var cleClient: UUID
    /// question, signalement ou changement.
    var moment: String
    var joint: ElementJoint?
    var ecran: String
}

/// Le corps de `POST /coach/question`, `/coach/signalement` et `/coach/changement`.
struct EnvoiAHAL: Encodable {
    let texte: String
    let cleClient: UUID
    let ecran: String
    let idOccurrence: Int?
    let lundi: String?
}

enum TexteHAL {
    private static let francais = Locale(identifier: "fr_FR")

    static func jour(_ texte: String?) -> String? {
        guard let texte, let date = Dates.lire(texte) else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(francais))
    }

    static func heure(_ texte: String?) -> String? {
        guard let texte, texte.count > 10, let date = Dates.lire(texte) else { return nil }
        return date.formatted(.dateTime.hour().minute().locale(francais))
    }

    static func jourISO(_ date: Date) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "Europe/Paris")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }

    static func nature(_ nature: String?) -> String {
        switch nature {
        case "alleger": "Alléger"
        case "modifier": "Modifier"
        case "deplacer": "Déplacer"
        case "retirer": "Retirer"
        default: nature?.capitalized ?? "Ajuster"
        }
    }

    static func avis(_ avis: String?) -> String? {
        switch avis {
        case "realiste": "Réaliste"
        case "ambitieux": "Ambitieux"
        case "irrealiste": "Irréaliste"
        default: avis
        }
    }

    static func role(_ role: String?) -> String {
        switch role {
        case "calibrage": "calibrage"
        case "charge": "charge"
        case "allegee": "allégée"
        case "test": "test"
        case "affutage": "affûtage"
        case "reprise": "reprise"
        default: role ?? ""
        }
    }
}
