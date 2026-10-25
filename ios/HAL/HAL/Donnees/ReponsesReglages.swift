import Foundation

// Ce que rendent les routes des Réglages (lot 8), tel quel : le foyer et ses
// invitations, les calendriers suivis et abonnés, les heures, l'Historique.

// MARK: - Calendriers à suivre (5.3, 5.4)

/// Un événement lu dans un calendrier : le prochain d'un flux suivi, ou ce que
/// donne un lien qu'on essaie (COL-7).
struct EvenementLu: Codable, Hashable, Sendable {
    let titre: String
    let debut: Date
    let fin: Date?
    let lieu: String?
    var journeeEntiere: Bool?
}

/// Un calendrier suivi du foyer, tel que `GET /appli/calendriers` le rend.
struct CalendrierSuivi: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let code: String
    let libelle: String
    let active: Bool
    let lienDonne: Bool
    /// « cours », « travail » ou « perso ».
    let nature: String
    /// Lu avec le profil de l'ADE : il a des groupes de TD et des UE à écarter (COL-17).
    let ade: Bool
    let groupe: Int?
    let coursEcartes: [String]
    let derniereCollecte: Date?
    /// « ok » ou « en_panne » (COL-9).
    let etat: String
    let pour: Int
    let pourNom: String
    let aVenir: Int
    let prochain: EvenementLu?

    var enPanne: Bool { active && lienDonne && etat == "en_panne" }

    /// Ce que dit la ligne sous le nom : l'état d'abord, s'il y a quelque chose à en dire.
    var etatEnClair: String {
        if !lienDonne { return "Lien à donner" }
        if !active { return "Arrêté" }
        if enPanne { return "Ne répond plus" }
        if let derniereCollecte {
            return "Lu " + derniereCollecte.formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_FR")))
        }
        return "Pas encore lu"
    }
}

/// Ce que l'essai d'un lien a trouvé, sans rien garder (COL-7).
struct EssaiLien: Codable, Sendable {
    let aVenir: Int
    let prochains: [EvenementLu]
}

/// Le bilan d'une collecte lancée par un réglage. `erreur` dit pourquoi elle n'a pas pu se faire.
struct CollecteLue: Codable, Hashable, Sendable {
    let lues: Int?
    let crees: Int?
    let misAJour: Int?
    let annules: Int?
    let conflits: Int?
    let erreur: String?

    /// « 12 ajoutés, 2 retirés », ou le motif d'un échec.
    var enClair: String {
        if let erreur { return erreur }
        var morceaux: [String] = []
        if let crees, crees > 0 { morceaux.append("\(crees) ajouté\(crees > 1 ? "s" : "")") }
        if let misAJour, misAJour > 0 { morceaux.append("\(misAJour) mis à jour") }
        if let annules, annules > 0 { morceaux.append("\(annules) retiré\(annules > 1 ? "s" : "")") }
        if let conflits, conflits > 0 { morceaux.append("\(conflits) conflit\(conflits > 1 ? "s" : "") à régler") }
        return morceaux.isEmpty ? "Rien n'a changé" : morceaux.joined(separator: ", ")
    }
}

struct CalendrierEtCollecte: Codable, Sendable {
    let calendrier: CalendrierSuivi
    let collecte: CollecteLue?
}

struct ArretDeCalendrier: Codable, Sendable {
    let calendrier: CalendrierSuivi
    let retirees: Int
}

// MARK: - Calendriers abonnés (5.12)

/// L'adresse d'abonnement de son planning complet (UTI-2).
struct LienAbonnement: Codable, Sendable {
    let url: String
    let webcal: String?
}

/// Un calendrier composé : des personnes et des familles de contenu (NOT-5, NOT-6).
struct CalendrierCompose: Codable, Identifiable, Hashable, Sendable {
    let idCalendrier: Int
    let libelle: String
    let personnes: [Int]
    let contenus: [String]
    let noms: [String]?
    let url: String?
    var id: Int { idCalendrier }
}

/// Les six familles de NOT-6, dans l'ordre d'affichage.
enum FamilleCalendrier: String, CaseIterable, Identifiable {
    case cours, travail, perso, taches, sport, weekends

    var id: String { rawValue }

    var libelle: String {
        switch self {
        case .cours: "Cours"
        case .travail: "Travail"
        case .perso: "Perso"
        case .taches: "Tâches"
        case .sport: "Sport"
        case .weekends: "Week-ends"
        }
    }

    var categorie: Categorie {
        switch self {
        case .cours: .cours
        case .travail: .travail
        case .perso, .weekends: .perso
        case .taches: .menage
        case .sport: .sport
        }
    }
}

// MARK: - Le foyer (5.15, 5.16)

/// Le foyer tel que `GET /foyer` le rend (FOY).
struct FoyerLu: Codable, Sendable {
    struct MembreLu: Codable, Identifiable, Hashable, Sendable {
        let idUtilisateur: Int
        let pseudo: String
        let nom: String
        let administrateur: Bool
        var id: Int { idUtilisateur }
    }

    struct InvitationLue: Codable, Identifiable, Hashable, Sendable {
        let idInvitation: Int
        let creeLe: Date?
        let expireLe: Date
        var id: Int { idInvitation }
    }

    let idFoyer: Int
    let nom: String
    let idAdministrateur: Int
    /// « tous » ou « admin » (FOY-6).
    let ajoutTaches: String
    let modifTaches: String
    /// HDF-1 : le HAL du foyer, actif par défaut.
    var halActif: Bool? = nil
    /// VER-8 : le jour (1, lundi, à 7) et l'heure, « 06:30:00 », de la
    /// vérification de la semaine.
    var verificationJour: Int? = nil
    var verificationHeure: String? = nil
    let placesLibres: Int
    let jeSuisAdmin: Bool
    let membres: [MembreLu]
    let invitations: [InvitationLue]
}

/// Une invitation qu'on vient de créer : le code n'est montré qu'à ce moment (FOY-3).
struct InvitationCreee: Codable, Identifiable, Sendable {
    let idInvitation: Int
    let expireLe: Date
    let code: String
    let serveur: String?
    let lien: String?
    var id: Int { idInvitation }
}

// MARK: - Mes heures (5.11)

/// Les heures de chacun, « 07:00 » (NOT-15).
struct HeuresLues: Codable, Equatable, Sendable {
    var bilan: String
    var relance: String
    var recap: String
    var silenceDebut: String
    var silenceFin: String
}

// MARK: - L'Historique (5.17)

/// Une action du journal et ce qu'elle a changé (JRN-4, JRN-9).
struct ActionJournal: Codable, Identifiable, Hashable, Sendable {
    struct Ligne: Codable, Hashable, Sendable {
        let objet: String
        let phrase: String
        let detail: String?
        let technique: Bool?
        let correspond: Bool?
    }

    let operation: String
    let quand: Date
    let acteur: String?
    let qui: String
    let origine: String?
    let action: String?
    let evenements: [Ligne]
    var id: String { operation }
}

// MARK: - Les heures en clair

enum Heure {
    private static let format: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm"
        return format
    }()

    /// « 07:00 » devient une date d'aujourd'hui à cette heure, pour un DatePicker.
    static func date(_ texte: String) -> Date {
        let lue = format.date(from: texte) ?? .now
        let parties = Calendar.current.dateComponents([.hour, .minute], from: lue)
        return Calendar.current.date(bySettingHour: parties.hour ?? 0, minute: parties.minute ?? 0,
                                     second: 0, of: .now) ?? .now
    }

    static func texte(_ date: Date) -> String { format.string(from: date) }

    /// « 7 h », « 23 h 30 ».
    static func enClair(_ texte: String) -> String {
        let morceaux = texte.split(separator: ":")
        guard morceaux.count == 2, let h = Int(morceaux[0]), let m = Int(morceaux[1]) else { return texte }
        return m == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", m))"
    }
}


/// HDF-4 : la mémoire du foyer, commune aux membres.
struct MemoireFoyerLue: Codable, Sendable {
    struct Etage: Codable, Hashable, Sendable {
        var texte: String = ""
        var longueur: Int? = nil
        var limite: Int? = nil
        /// Le membre qui l'a corrigée en dernier ; vide si c'est HAL.
        var nomAuteur: String? = nil
        var quand: Date? = nil
        /// « 2026-10-19 » pour une semaine.
        var periode: String? = nil
    }

    var globale: Etage? = nil
    var semaine: Etage? = nil
    var semainesPassees: [Etage] = []
}
