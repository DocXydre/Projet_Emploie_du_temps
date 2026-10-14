import Foundation

/// Ce que l'appli garde pour ses widgets iOS (IOS-1, IOS-2) : ils le lisent tel
/// quel, sans appel au serveur de leur côté. Écrit à chaque chargement réussi,
/// dans le dossier partagé du groupe d'applications.
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

    var misAJour: Date
    var sport: Sport
    var forme: Forme
    var journee: [Moment]
    /// HAL a quelque chose à dire (NOT-18).
    var halADire: Bool

    static let exemple = Instantane(
        misAJour: .now,
        sport: Sport(faites: 1, prevues: 4, prochaine: "Ven. 16:30 · Test 3 km"),
        forme: Forme(sommeilMinutes: 452, fcRepos: 52, pas: 8140),
        journee: [Moment(debut: .now.addingTimeInterval(1800), fin: .now.addingTimeInterval(9000),
                         titre: "TD Système FI", lieu: "Amphi 201", categorie: "cours"),
                  Moment(debut: .now.addingTimeInterval(14400), titre: "Footing facile", categorie: "sport")],
        halADire: false)

    /// Ce qui n'est pas encore passé, dans l'ordre.
    func aVenir(_ maintenant: Date = .now) -> [Moment] {
        journee.filter { ($0.fin ?? $0.debut) >= maintenant }.sorted { $0.debut < $1.debut }
    }
}

/// Le dossier partagé entre l'appli et ses widgets.
enum Partage {
    static let groupe = "group.fr.docxydre.hal"

    private static var fichier: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupe)?
            .appendingPathComponent("instantane.json")
    }

    static func ecrire(_ instantane: Instantane) {
        guard let fichier, let donnees = try? JSONEncoder().encode(instantane) else { return }
        try? donnees.write(to: fichier, options: .atomic)
    }

    static func lire() -> Instantane? {
        guard let fichier, let donnees = try? Data(contentsOf: fichier) else { return nil }
        return try? JSONDecoder().decode(Instantane.self, from: donnees)
    }
}
