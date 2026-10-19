import BackgroundTasks
import Foundation
import HealthKit
import Observation

/// Tout le détail de Santé, sur tout l'historique (SAN-11 à SAN-16, 5.10).
///
/// Chaque type a son ancre, gardée sur le téléphone : la première fois, elle
/// est vide et Santé rend l'historique par morceaux ; ensuite, seulement ce qui
/// est arrivé depuis. L'ancre n'avance qu'une fois le morceau envoyé : coupé en
/// route, l'envoi reprend là où il s'était arrêté, et le serveur ignore ce
/// qu'il a déjà (SAN-3). Les envois portent au plus 4 000 lignes.
@MainActor
@Observable
final class CollecteSante {
    nonisolated static let idTache = "fr.docxydre.hal.sante.historique"
    private static let taillePaquet = 4000

    /// Ce qui reste de l'historique, pour 5.10.
    private(set) var seancesTotal: Int?
    private(set) var seancesEnvoyees = 0
    private(set) var premiereSeance: Date?
    /// Pour chaque type, la date la plus récente déjà envoyée, et s'il a fini
    /// son historique.
    private(set) var atteint: [String: Date] = [:]
    private(set) var termines: Set<String> = []
    private(set) var enCours = false
    private(set) var dernierBilan: String?

    private let lecteur: LecteurSante
    private let reglages = UserDefaults.standard

    init(lecteur: LecteurSante) {
        self.lecteur = lecteur
        seancesEnvoyees = reglages.integer(forKey: "sante.detail.seances_envoyees")
        termines = Set(reglages.stringArray(forKey: "sante.detail.termines") ?? [])
        if let dates = reglages.dictionary(forKey: "sante.detail.atteint") as? [String: Date] {
            atteint = dates
        }
    }

    // MARK: L'avancée

    /// Les voies que les cases de Réglages ouvrent.
    private func voies(_ lues: Set<EnvoiSante.Donnee>) -> [String] {
        var voies: [String] = []
        if lues.contains(.seances) { voies.append("seances") }
        if lues.contains(.sommeil) { voies.append("sommeil") }
        for flux in FluxSante.allCases where lues.contains(flux.donnee) {
            voies += flux.grandeurs.map { $0.type.rawValue }
        }
        return voies
    }

    /// De 0 à 1 : les séances au nombre, le reste à la date atteinte.
    func avancee(_ lues: Set<EnvoiSante.Donnee>) -> Double {
        let voies = voies(lues)
        guard !voies.isEmpty else { return 1 }
        let debut = premiereSeance ?? Calendar.current.date(byAdding: .year, value: -2, to: .now) ?? .now
        let total = Date.now.timeIntervalSince(debut)
        let parts = voies.map { voie -> Double in
            if termines.contains(voie) { return 1 }
            if voie == "seances", let seancesTotal, seancesTotal > 0 {
                return min(1, Double(seancesEnvoyees) / Double(seancesTotal))
            }
            guard let date = atteint[voie], total > 0 else { return 0 }
            return min(1, max(0, date.timeIntervalSince(debut) / total))
        }
        return parts.reduce(0, +) / Double(parts.count)
    }

    func historiqueFini(_ lues: Set<EnvoiSante.Donnee>) -> Bool {
        voies(lues).allSatisfy(termines.contains)
    }

    /// « Depuis mars 2021 : 1 240 séances sur 1 940, et la FC jusqu'en juin 2023. »
    func resume(_ lues: Set<EnvoiSante.Donnee>) -> String {
        let mois = Date.FormatStyle().month(.wide).year().locale(Locale(identifier: "fr_FR"))
        var morceaux: [String] = []
        if lues.contains(.seances), let seancesTotal {
            morceaux.append("\(seancesEnvoyees) séance\(seancesEnvoyees > 1 ? "s" : "") sur \(seancesTotal)")
        }
        let fc = HKQuantityTypeIdentifier.heartRate.rawValue
        if lues.contains(.frequence), !termines.contains(fc), let date = atteint[fc] {
            morceaux.append("la FC jusqu'en \(date.formatted(mois))")
        }
        let debut = premiereSeance.map { "Depuis \($0.formatted(mois)) : " } ?? ""
        return morceaux.isEmpty ? "" : debut + morceaux.joined(separator: ", et ") + "."
    }

    // MARK: L'envoi

    /// Avance l'historique jusqu'à l'heure dite, ou jusqu'au bout. Rend vrai
    /// si tout est envoyé. S'arrête si le serveur ne répond plus, ou si iOS
    /// reprend la main (la tâche est annulée).
    @discardableResult
    func avancer(lues: Set<EnvoiSante.Donnee>, client: ClientAPI, jusqua limite: Date) async -> Bool {
        guard !enCours else { return false }
        self.client = client
        enCours = true
        defer { enCours = false }
        if seancesTotal == nil {
            seancesTotal = await lecteur.nombreDeSeances()
            premiereSeance = await lecteur.premiereSeance()
        }

        var lignes = 0
        var echecs = 0
        do {
            var reste = true
            while reste, Date.now < limite, !Task.isCancelled {
                reste = false
                if lues.contains(.seances) {
                    let (envoyees, encore) = try await seances(lues: lues, client: client)
                    lignes += envoyees
                    reste = reste || encore
                }
                if lues.contains(.sommeil) {
                    let (envoyees, encore) = try await sommeil(client: client)
                    lignes += envoyees
                    reste = reste || encore
                }
                for flux in FluxSante.allCases where lues.contains(flux.donnee) {
                    for grandeur in flux.grandeurs {
                        guard Date.now < limite, !Task.isCancelled else { break }
                        let (envoyees, encore) = try await echantillons(grandeur, client: client)
                        lignes += envoyees
                        reste = reste || encore
                    }
                }
            }
        } catch let erreur as ErreurAPI where erreur.injoignable {
            dernierBilan = "Serveur injoignable : l'historique reprendra plus tard"
            return false
        } catch {
            echecs += 1
        }
        enregistrer()
        let fini = historiqueFini(lues)
        if !fini { Self.planifier() }
        if !fini || echecs > 0 {
            dernierBilan = "\(lignes) lignes de plus envoyées" + (echecs > 0 ? ", \(echecs) échec(s)" : "")
        } else if dernierBilan?.hasPrefix("Refusé") != true {
            dernierBilan = nil
        }
        return fini
    }

    /// « Tout renvoyer depuis le début » : les ancres s'effacent, le serveur
    /// ignorera ce qu'il a déjà.
    func toutRenvoyer() {
        for cle in reglages.dictionaryRepresentation().keys where cle.hasPrefix("sante.ancre.") {
            reglages.removeObject(forKey: cle)
        }
        seancesEnvoyees = 0
        termines = []
        atteint = [:]
        enregistrer()
        Self.planifier()
    }

    // MARK: Les séances

    /// Cinq séances à la fois : le résumé, puis ses mesures, son découpage et
    /// son tracé. Une séance dont le détail échoue garde son résumé.
    private func seances(lues: Set<EnvoiSante.Donnee>, client: ClientAPI) async throws -> (Int, Bool) {
        let ancre = ancre("seances")
        let (seances, nouvelle) = try await lecteur.seances(apres: ancre, limite: 5)
        var lignes = 0
        for seance in seances {
            let cle = seance.uuid.uuidString
            try await envoyer("PUT", "donnees-sante/activites/\(cle)", json: lecteur.resumeEnvoye(seance))
            if lues.contains(.detailSeances) {
                let mesures = await lecteur.mesures(de: seance)
                for paquet in mesures.paquets(Self.taillePaquet) {
                    try await envoyer("PUT", "donnees-sante/activites/\(cle)/series",
                                      corps: ClientAPI.corps(["series": paquet]))
                }
                let segments = lecteur.decoupage(de: seance)
                    + LecteurSante.kilometres(mesures, debut: seance.startDate)
                if !segments.isEmpty {
                    try await envoyer("PUT", "donnees-sante/activites/\(cle)/segments",
                                      corps: ClientAPI.corps(["segments": segments]))
                }
                lignes += mesures.count + segments.count
            }
            if lues.contains(.trace) {
                let points = await lecteur.trace(de: seance)
                for paquet in points.paquets(Self.taillePaquet) {
                    try await envoyer("PUT", "donnees-sante/activites/\(cle)/trace",
                                      corps: ClientAPI.corps(["points": paquet]))
                }
                lignes += points.count
            }
            seancesEnvoyees += 1
        }
        garder(nouvelle, pour: "seances", dernier: seances.map(\.endDate).max(), fini: seances.count < 5)
        return (lignes + seances.count, seances.count == 5)
    }

    // MARK: Le quotidien et le sommeil

    private func echantillons(_ grandeur: GrandeurLue, client: ClientAPI) async throws -> (Int, Bool) {
        let voie = grandeur.type.rawValue
        let (lignes, nouvelle, dernier) = try await lecteur.echantillons(grandeur, apres: ancre(voie),
                                                                       limite: Self.taillePaquet)
        if !lignes.isEmpty {
            try await envoyer("PUT", "donnees-sante/echantillons",
                              corps: ClientAPI.corps(["echantillons": lignes]))
        }
        let plein = lignes.count == Self.taillePaquet
        garder(nouvelle, pour: voie, dernier: dernier, fini: !plein)
        return (lignes.count, plein)
    }

    private func sommeil(client: ClientAPI) async throws -> (Int, Bool) {
        let (phases, nouvelle, dernier) = try await lecteur.phasesDeSommeil(apres: ancre("sommeil"),
                                                                           limite: Self.taillePaquet)
        if !phases.isEmpty {
            try await envoyer("PUT", "donnees-sante/sommeil", corps: ClientAPI.corps(["phases": phases]))
        }
        let plein = phases.count == Self.taillePaquet
        garder(nouvelle, pour: "sommeil", dernier: dernier, fini: !plein)
        return (phases.count, plein)
    }

    // MARK: Outils

    var client: ClientAPI?

    /// Un refus du serveur (une ligne qu'il ne veut pas) n'arrête pas
    /// l'historique : le morceau est compté comme envoyé. Seul un serveur
    /// injoignable arrête tout, sans avancer l'ancre.
    private func envoyer(_ methode: String, _ chemin: String, corps: Data?) async throws {
        guard let client else { throw ErreurAPI.injoignableSansServeur }
        do {
            try await client.envoyer(methode, chemin, corps: corps, delai: 60)
        } catch let erreur as ErreurAPI where !erreur.injoignable {
            dernierBilan = "Refusé : \(erreur.message)"
        }
    }

    private func envoyer(_ methode: String, _ chemin: String, json: [String: Any]) async throws {
        try await envoyer(methode, chemin, corps: try? JSONSerialization.data(withJSONObject: json))
    }

    private func ancre(_ voie: String) -> HKQueryAnchor? {
        guard let donnees = reglages.data(forKey: "sante.ancre.\(voie)") else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: donnees)
    }

    private func garder(_ ancre: HKQueryAnchor, pour voie: String, dernier: Date?, fini: Bool) {
        if let donnees = try? NSKeyedArchiver.archivedData(withRootObject: ancre, requiringSecureCoding: true) {
            reglages.set(donnees, forKey: "sante.ancre.\(voie)")
        }
        if let dernier, dernier > (atteint[voie] ?? .distantPast) { atteint[voie] = dernier }
        if fini { termines.insert(voie) }
        enregistrer()
    }

    private func enregistrer() {
        reglages.set(seancesEnvoyees, forKey: "sante.detail.seances_envoyees")
        reglages.set(Array(termines), forKey: "sante.detail.termines")
        reglages.set(atteint, forKey: "sante.detail.atteint")
    }

    // MARK: Arrière-plan

    /// L'historique avance quand l'iPhone est branché et en ligne : iOS
    /// laisse alors plusieurs minutes, là où l'envoi courant n'en a que quelques-unes.
    nonisolated static func planifier() {
        let demande = BGProcessingTaskRequest(identifier: idTache)
        demande.requiresExternalPower = true
        demande.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(demande)
    }
}

extension FluxSante {
    /// La case de Réglages qui ouvre ce flux.
    var donnee: EnvoiSante.Donnee {
        switch self {
        case .frequence: .frequence
        case .forme: .vfc
        case .poids: .poids
        case .nuit: .nuit
        case .energie: .pas
        }
    }
}

extension ErreurAPI {
    static let injoignableSansServeur = ErreurAPI(code: "injoignable", message: "Pas de serveur", statut: 0)
}

extension Array {
    /// Des morceaux d'au plus `taille` éléments.
    func paquets(_ taille: Int) -> [[Element]] {
        stride(from: 0, to: count, by: taille).map { Array(self[$0..<Swift.min($0 + taille, count)]) }
    }
}

extension LecteurSante {
    /// Le résumé d'une séance, comme `SeanceMontre.corps` l'envoie déjà.
    func resumeEnvoye(_ entrainement: HKWorkout) -> [String: Any] {
        seance(de: entrainement).corps
    }
}
