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
        /// TAC-25 : sa couleur et son icône. Absent d'une réponse gardée avant la 067.
        let type: TypeTache?
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
    /// TAC-25 : les types du foyer, pour le formulaire hors réseau.
    let types: [TypeTache]?
    /// ACC-13 : ce qu'un modèle a demandé et qui attend l'accord. Absent d'une
    /// réponse gardée avant la partie F.
    let demandes: [DemandeAPI]?
}

/// Une demande en attente (ACC-2) : ce qui changerait, et pourquoi.
struct DemandeAPI: Codable, Identifiable, Hashable, Sendable {
    let idDemande: Int
    let action: String
    let resume: String
    let motif: String
    let origine: String
    let client: String?
    let expireLe: Date?
    var id: Int { idDemande }

    /// Qui la propose : HAL dans l'appli, ou le client MCP.
    var auteur: String { client.map { $0.components(separatedBy: "/").first ?? $0 } ?? "HAL" }
}

/// Une tâche du foyer, telle que `GET /taches` la rend : régulière, ponctuelle
/// ou née d'une autre (TAC-20 à TAC-24). Tout est optionnel sauf l'identité,
/// pour qu'un serveur plus ancien se lise encore.
struct TacheRecurrente: Codable, Identifiable, Hashable {
    struct Fenetre: Codable, Hashable {
        let debut: Date
        let fin: Date
    }

    let idTache: Int
    let code: String
    let libelle: String
    let categorie: String
    var type: TypeTache? = nil
    var dureeMinutes: Int? = nil
    var periodiciteMinJours: Int? = nil
    var periodiciteMaxJours: Int? = nil
    var rappelJournee: Bool? = nil
    /// « 18:30:00 », tel que la base l'écrit.
    var heureMin: String? = nil
    var heureMax: String? = nil
    var recurrente: Bool? = nil
    var active: Bool? = nil
    var idUtilisateurDefaut: Int? = nil
    var siPasFaite: String? = nil
    /// La fenêtre de la prochaine fois, pour une tâche ponctuelle.
    var dates: Fenetre? = nil
    /// TAC-27 : elle naît d'un lien « Ensuite ».
    var naitDUneAutre: Bool? = nil
    /// CND-4 : N fois par semaine ou par mois, au lieu de tous les N jours.
    var rythmeNombre: Int? = nil
    var rythmePeriode: String? = nil
    var rythmeMoment: String? = nil
    /// CND-16 : combien de règles spéciales actives.
    var regles: Int? = nil
    var id: Int { idTache }

    var sansHeure: Bool { rappelJournee ?? true }
    /// TAC-23 : « à 18h30 » est une plage de la longueur exacte de la tâche.
    var aUneHeure: Bool {
        guard let debut = HeureDuJour(heureMin), let fin = HeureDuJour(heureMax), let duree = dureeMinutes else { return false }
        return fin.minutes - debut.minutes == duree
    }

    /// « tous les 2 à 3 j », « le 23/10 », « après une autre », sans rien calculer
    /// d'autre que la mise en mots.
    var rythme: String {
        if recurrente == false {
            if naitDUneAutre == true { return "après une autre" }
            guard let dates else { return "une fois" }
            let du = Fenetre.court(dates.debut)
            let au = Fenetre.court(dates.fin.addingTimeInterval(-1))
            return du == au ? (Calendar.current.isDateInToday(dates.debut) ? "aujourd'hui" : "le \(du)")
                            : "du \(du) au \(au)"
        }
        if let fois = rythmeNombre, let par = rythmePeriode {
            return "\(fois == 1 ? "une fois" : "\(fois) fois") par \(par)"
        }
        guard let min = periodiciteMinJours, let max = periodiciteMaxJours else { return "" }
        if min == 1 && max <= 1 { return "tous les jours" }
        if min == 7 && max <= 8 { return "chaque semaine" }
        return min == max ? "tous les \(min) j" : "tous les \(min) à \(max) j"
    }

    /// « 18h30 », « 21h45–23h30 », ou rien pour un rappel de journée.
    var heure: String? {
        guard !sansHeure, let debut = HeureDuJour(heureMin), let fin = HeureDuJour(heureMax) else { return nil }
        return aUneHeure ? debut.texte : "\(debut.texte)–\(fin.texte)"
    }
}

private extension TacheRecurrente.Fenetre {
    static func court(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).locale(Locale(identifier: "fr_FR")))
    }
}

/// Une heure du jour, lue ou écrite comme la base : « 18:30 ».
struct HeureDuJour: Hashable {
    var minutes: Int

    init(minutes: Int) { self.minutes = max(0, min(24 * 60 - 1, minutes)) }

    init?(_ texte: String?) {
        guard let texte else { return nil }
        let morceaux = texte.split(separator: ":").compactMap { Int($0) }
        guard morceaux.count >= 2 else { return nil }
        self.init(minutes: morceaux[0] * 60 + morceaux[1])
    }

    init(_ date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.init(minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// Pour l'API : « 18:30 ».
    var api: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    /// Pour l'œil : « 18h30 », « 18h ».
    var texte: String { minutes % 60 == 0 ? "\(minutes / 60)h" : String(format: "%dh%02d", minutes / 60, minutes % 60) }
    /// Pour un sélecteur d'heure : aujourd'hui à cette heure.
    var date: Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }
}

/// Un type de tâche du foyer (TAC-25), tel que `/types-taches` le rend.
struct TypeTache: Codable, Identifiable, Hashable {
    let id: Int
    let libelle: String
    let couleur: String
    let icone: String
    var dureeMinutes: Int? = nil
    var priorite: Int? = nil
    var categorie: String? = nil
    /// Ses tâches actives : un type n'est supprimable qu'à zéro (TAC-26).
    var taches: Int? = nil
}

/// Un lien entre deux tâches (TAC-27), lu depuis l'une d'elles. La phrase est
/// écrite par la base, dans le sens où on la lit.
struct LienTache: Codable, Identifiable, Hashable {
    let sorte: String
    let idLien: Int
    let idDe: Int
    let libelleDe: String
    let idVers: Int
    let libelleVers: String
    let depuis: Bool
    let phrase: String
    let idAutre: Int
    var delaiMinHeures: Int? = nil
    var delaiMaxHeures: Int? = nil
    var place: String? = nil
    var id: String { "\(sorte)-\(idLien)" }

    var etiquette: String {
        switch sorte {
        case "ensuite": depuis ? "ENSUITE" : "NAÎT APRÈS"
        case "meme_jour": "LE MÊME JOUR"
        default: depuis ? "VAUT AUSSI" : "COUVERTE PAR"
        }
    }

    var icone: String {
        switch sorte {
        case "ensuite": "arrow.2.squarepath"
        case "meme_jour": "calendar"
        default: "checkmark"
        }
    }
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


// MARK: - Les règles spéciales d'une tâche                     (CND-1 à CND-16)

/// Les paramètres d'une brique : seuls ceux de sa nature sont remplis.
struct ParametresBrique: Codable, Hashable {
    var jours: [Int]? = nil
    var dates: [String]? = nil
    var rang: Int? = nil
    var jourSemaine: Int? = nil
    var partie: String? = nil
    var heures: Double? = nil
    var minutes: Int? = nil
    /// « Avant un départ » : combien de jours avant.
    var joursAvant: Int? = nil
}

/// Une brique d'une règle (CND-3 à CND-6). `phrase` vient de la base, en lecture.
struct BriqueRegle: Codable, Hashable, Identifiable {
    var nature: String
    var pourQui: String? = nil
    var idUtilisateur: Int? = nil
    var parametres = ParametresBrique()
    var phrase: String? = nil
    var id: String { nature }

    enum CodingKeys: String, CodingKey { case nature, pourQui, idUtilisateur, parametres, phrase }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nature, forKey: .nature)
        try c.encodeIfPresent(pourQui, forKey: .pourQui)
        try c.encodeIfPresent(idUtilisateur, forKey: .idUtilisateur)
        try c.encode(parametres, forKey: .parametres)
    }
}

struct FrequenceRegle: Codable, Hashable {
    var min: Int? = nil
    var max: Int? = nil
    var fois: Int? = nil
    var par: String? = nil
}

/// Une règle spéciale, telle que `v_regle_tache` la rend.
struct RegleTache: Codable, Identifiable, Hashable {
    let idRegleTache: Int
    let idTache: Int
    var phrase: String? = nil
    let traduction: String
    /// « 2026-06-01 » : un jour, sans heure.
    var valideDu: String? = nil
    var valideAu: String? = nil
    var chaqueAnnee: Bool? = nil
    var frequence: FrequenceRegle? = nil
    let etat: String
    var poseeParNom: String? = nil
    var briques: [BriqueRegle] = []
    /// CND-12 : depuis quand aucun jour ne tient la règle.
    var impossibleDepuis: Date? = nil
    var id: Int { idRegleTache }

    var active: Bool { etat == "active" }
}

/// Le détail d'une tâche lit ses règles et ses prochains jours possibles.
struct ReglesDeTache: Codable, Hashable {
    var regles: [RegleTache] = []
    /// « 2026-10-23 », les cinq prochains.
    var prochainsJours: [String] = []
}

/// Ce que rend l'essai d'une règle, avant de la poser.
struct EssaiRegle: Codable, Hashable {
    var traduction: String? = nil
    var jours: [String] = []
}
