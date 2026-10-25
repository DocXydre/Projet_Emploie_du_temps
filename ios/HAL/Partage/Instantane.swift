import Foundation

/// Ce que l'appli garde pour ses widgets iOS (IOS-1, IOS-2) : ils le lisent tel
/// quel, sans appel au serveur de leur côté. Écrit à chaque chargement réussi,
/// dans le dossier partagé du groupe d'applications.
///
/// Les textes arrivent déjà écrits en français : les widgets les posent sans
/// les refaire. Seul ce qui dépend de l'heure reste en dates.
struct Instantane: Codable, Equatable, Sendable {
    struct Sport: Codable, Equatable, Sendable {
        var faites: Int
        var prevues: Int
        /// « Ven. 16:30 · Test 3 km ».
        var prochaine: String?
    }

    struct Forme: Codable, Equatable, Sendable {
        var sommeilMinutes: Int?
        var fcRepos: Int?
        var pas: Int?
        var vfc: Int? = nil
    }

    struct Moment: Codable, Equatable, Identifiable, Sendable {
        var debut: Date
        var fin: Date?
        var titre: String
        var lieu: String?
        /// Le nom de la catégorie (cours, travail, sport…), pour sa couleur.
        var categorie: String
        var id: String { "\(debut.timeIntervalSince1970)-\(titre)" }
    }

    /// Une tâche du jour, pour « À cocher ».
    struct Tache: Codable, Equatable, Identifiable, Sendable {
        var titre: String
        var faite: Bool
        /// Le prénom de qui la fait, quand le foyer compte deux personnes.
        var pourQui: String?
        var id: String { "\(titre)-\(pourQui ?? "")" }
    }

    /// La tâche la plus en retard : « reportée 2 fois », « depuis hier ».
    struct EnRetard: Codable, Equatable, Sendable {
        var titre: String
        var detail: String
        var nombre: Int
    }

    struct Objectif: Codable, Equatable, Sendable {
        var titre: String
        var joursRestants: Int
        /// De 0 à 1.
        var avancee: Double
    }

    /// Les tâches du type Chat et leur prochaine fois, trois au plus.
    struct Chat: Codable, Equatable, Sendable {
        struct Soin: Codable, Equatable, Sendable {
            var titre: String
            var quand: String
        }
        var soins: [Soin]
    }

    /// Le temps passé aux tâches partagées sur sept jours.
    struct Equilibre: Codable, Equatable, Sendable {
        /// De 0 à 1.
        var partDeMoi: Double
        var autre: String?
        /// « 2 h 10 »
        var dureeMoi: String
        var dureeAutre: String?
    }

    /// Une ligne écrite : le linge, ce qui arrive bientôt, la proposition de week-end.
    struct Ligne: Codable, Equatable, Identifiable, Sendable {
        var titre: String
        var detail: String?
        /// L'initiale de qui la fait, quand le foyer compte deux personnes.
        var qui: String? = nil
        var id: String { "\(titre)-\(detail ?? "")-\(qui ?? "")" }
    }

    struct Train: Codable, Equatable, Sendable {
        /// « Paris → Lyon »
        var trajet: String
        var depart: Date
        /// « 2 h 10 · 1 corresp. »
        var detail: String
    }

    /// Un bloc de la semaine, à son heure, dans la couleur de sa famille.
    struct Bloc: Codable, Equatable, Sendable {
        var debut: Date
        var fin: Date?
        var categorie: String
    }

    /// La dernière séance de la montre, ou la dernière course.
    struct SeanceMontre: Codable, Equatable, Sendable {
        var titre: String
        /// La distance pour ce qui se court, la durée sinon.
        var principal: String
        var fcMoyenne: Int?
        var debut: Date
        var duree: String? = nil
        var allure: String? = nil
    }

    var misAJour: Date
    var sport: Sport
    var forme: Forme
    var journee: [Moment]
    /// HAL a quelque chose à dire (NOT-18).
    var halADire: Bool
    // Tout ce qui suit est venu après : un instantané plus ancien ne l'a pas.
    var sansMontre: Bool? = nil
    var taches: [Tache]? = nil
    var enRetard: EnRetard? = nil
    var objectif: Objectif? = nil
    var chat: Chat? = nil
    var equilibre: Equilibre? = nil
    /// La fréquence cardiaque du jour, dans l'ordre, sans les trous.
    var frequence: [Double]? = nil
    var weekend: Ligne? = nil
    var train: Train? = nil
    var semaine: [Bloc]? = nil
    var montre: SeanceMontre? = nil
    var derniereCourse: SeanceMontre? = nil
    var linge: [Ligne]? = nil
    var bientot: [Ligne]? = nil

    static let exemple = Instantane(
        misAJour: .now,
        sport: Sport(faites: 1, prevues: 4, prochaine: "Ven. 16:30 · Test 3 km"),
        forme: Forme(sommeilMinutes: 452, fcRepos: 52, pas: 8140, vfc: 61),
        journee: [Moment(debut: .now.addingTimeInterval(1800), fin: .now.addingTimeInterval(9000),
                         titre: "TD Système FI", lieu: "Amphi 201", categorie: "cours"),
                  Moment(debut: .now.addingTimeInterval(14400), titre: "Footing facile", categorie: "sport")],
        halADire: false,
        sansMontre: false,
        taches: [Tache(titre: "Vaisselle", faite: true, pourQui: "Toi"),
                 Tache(titre: "Litière", faite: false, pourQui: "Alex"),
                 Tache(titre: "Lessive blanche", faite: false, pourQui: "Toi")],
        enRetard: EnRetard(titre: "Aspirateur", detail: "reportée 2 fois", nombre: 1),
        objectif: Objectif(titre: "10 km sous 50 min", joursRestants: 38, avancee: 0.42),
        chat: Chat(soins: [.init(titre: "Litière", quand: "ce soir"), .init(titre: "Eau", quand: "demain"),
                           .init(titre: "Fontaine", quand: "sam. 24 oct.")]),
        equilibre: Equilibre(partDeMoi: 0.55, autre: "Alex", dureeMoi: "3 h 20", dureeAutre: "2 h 45"),
        frequence: [58, 61, 64, 72, 88, 76, 69, 65, 63, 70, 74, 66],
        weekend: Ligne(titre: "Week-end libre à Lyon ?", detail: "Du sam. 24 oct. au dim. 25 oct."),
        train: Train(trajet: "Paris → Lyon", depart: .now.addingTimeInterval(86_400 * 2), detail: "2 h 04"),
        semaine: semaineExemple,
        montre: SeanceMontre(titre: "Course", principal: "5,2 km", fcMoyenne: 152,
                             debut: .now.addingTimeInterval(-86_400)),
        derniereCourse: SeanceMontre(titre: "Course", principal: "5,2 km", fcMoyenne: 152,
                                     debut: .now.addingTimeInterval(-86_400), duree: "27:41", allure: "5:19"),
        linge: [Ligne(titre: "Machine blanc", detail: "aujourd'hui · 18:00"),
                Ligne(titre: "Étendre", detail: "aujourd'hui · 20:00")],
        bientot: [Ligne(titre: "Courses", detail: "Ven.", qui: "T"),
                  Ligne(titre: "Ménage salon", detail: "Sam.", qui: "A")])

    /// Quelques blocs dans la semaine en cours, pour l'aperçu de la galerie d'iOS.
    private static var semaineExemple: [Bloc] {
        let calendrier = Calendar.current
        let lundi = calendrier.date(from: calendrier.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                                     from: .now)) ?? .now
        let blocs: [(jour: Int, heure: Int, duree: Int, categorie: String)] = [
            (0, 8, 4, "cours"), (0, 18, 1, "sport"), (1, 9, 3, "travail"), (1, 20, 1, "menage"),
            (2, 8, 5, "cours"), (3, 14, 3, "travail"), (3, 19, 1, "sport"), (4, 10, 2, "cours"),
            (5, 10, 1, "linge"), (5, 17, 2, "sport"), (6, 11, 1, "chat")]
        return blocs.compactMap { bloc in
            guard let jour = calendrier.date(byAdding: .day, value: bloc.jour, to: lundi),
                  let debut = calendrier.date(bySettingHour: bloc.heure, minute: 0, second: 0, of: jour)
            else { return nil }
            return Bloc(debut: debut, fin: debut.addingTimeInterval(Double(bloc.duree) * 3600), categorie: bloc.categorie)
        }
    }

    /// Ce qui n'est pas encore passé, dans l'ordre.
    func aVenir(_ maintenant: Date = .now) -> [Moment] {
        journee.filter { ($0.fin ?? $0.debut) >= maintenant }.sorted { $0.debut < $1.debut }
    }
}

/// La séance de musculation en cours, pour son widget de l'écran d'accueil. La
/// même que celle de la Live Activity (IOS-3).
struct SeanceEnWidget: Codable, Equatable, Sendable {
    var titre: String
    var debut: Date
    var etat: AttributsSeance.ContentState
}

/// La dernière chose que HAL a dite, pour son widget.
struct MotDeHAL: Codable, Equatable, Sendable {
    var texte: String
}

/// Le dossier partagé entre l'appli et ses widgets. Chaque partie de l'appli y
/// écrit son fichier : le foyer, la séance en cours, HAL.
enum Partage {
    static let groupe = "group.fr.docxydre.hal.partage"

    private static func fichier(_ nom: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupe)?
            .appendingPathComponent(nom)
    }

    static func ecrire(_ instantane: Instantane) {
        ecrire(instantane, dans: "instantane.json")
    }

    static func lire() -> Instantane? {
        lire("instantane.json")
    }

    /// Rien à écrire efface le fichier : plus de séance en cours, par exemple.
    static func ecrire<Valeur: Encodable>(_ valeur: Valeur?, dans nom: String) {
        guard let fichier = fichier(nom) else { return }
        guard let valeur else {
            try? FileManager.default.removeItem(at: fichier)
            return
        }
        guard let donnees = try? JSONEncoder().encode(valeur) else { return }
        try? donnees.write(to: fichier, options: .atomic)
    }

    static func lire<Valeur: Decodable>(_ nom: String) -> Valeur? {
        guard let fichier = fichier(nom), let donnees = try? Data(contentsOf: fichier) else { return nil }
        return try? JSONDecoder().decode(Valeur.self, from: donnees)
    }
}
