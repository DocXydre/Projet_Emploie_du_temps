import BackgroundTasks
import Foundation
import Observation

/// Lit Santé et envoie au serveur, tout seul (SAN-10) : à l'ouverture de
/// l'appli, puis quand iOS la réveille en arrière-plan. Repris de la bêta.
///
/// Une valeur absente reste absente, jamais un zéro (SAN-5). Le serveur range
/// les séances de la montre avec les séances prévues (SAN-2).
@MainActor
@Observable
final class EnvoiSante {
    nonisolated static let idTache = "fr.docxydre.hal.sante"

    nonisolated static let idHistorique = CollecteSante.idTache
    /// Pour la tâche de fond de l'historique, enregistrée hors de SwiftUI.
    static weak var actuel: EnvoiSante?

    /// SAN-10 : ce que l'appli lit, coché dans Réglages (5.10). Tout l'est au départ.
    enum Donnee: String, CaseIterable, Identifiable {
        case pas, frequence, vfc, sommeil, seances, detailSeances, trace, poids, nuit

        var id: String { rawValue }

        var libelle: String {
            switch self {
            case .pas: "Pas et activité"
            case .frequence: "FC de toute la journée"
            case .vfc: "VFC, VO2max, récupération"
            case .sommeil: "Sommeil par phases"
            case .seances: "Séances de la montre"
            case .detailSeances: "Détail des séances"
            case .trace: "Tracé GPS des séances"
            case .poids: "Poids"
            case .nuit: "SpO2, respiration, température"
            }
        }

        var icone: String {
            switch self {
            case .pas: "figure.walk"
            case .frequence: "heart"
            case .vfc: "flame"
            case .sommeil: "bed.double"
            case .seances: "applewatch"
            case .detailSeances: "chart.xyaxis.line"
            case .trace: "map"
            case .poids: "scalemass"
            case .nuit: "moon"
            }
        }

        /// Les cases de la version d'avant (lot 6c) : celles qui manquent
        /// arrivent cochées, comme tout au départ.
        static let ajouteesAuDetail: Set<Donnee> = [.frequence, .detailSeances, .trace, .poids, .nuit]
    }

    /// Ce qui est coché. Une case décochée n'est plus envoyée ; ce qui est déjà
    /// sur le serveur y reste.
    var lues: Set<Donnee> = Set(Donnee.allCases) {
        didSet { reglages.set(lues.map(\.rawValue), forKey: "sante.lues") }
    }

    private(set) var enCours = false
    /// PRE-2 : la fenêtre d'iOS a déjà été montrée. Tant qu'elle ne l'a pas été,
    /// rien n'est lu : elle ne s'ouvre qu'après l'écran qui explique, au premier
    /// lancement, dans Sport ou dans Réglages.
    private(set) var accesDemande = true
    private(set) var dernierEnvoi: Date?
    private(set) var dernierBilan: String?
    private(set) var frequenceDuJour: [PointSerie] = []

    let lecteur = LecteurSante()
    /// SAN-11 à SAN-16 : tout le détail, sur tout l'historique.
    let collecte: CollecteSante
    private let reglages = UserDefaults.standard
    private var dernierEssai: Date?
    var client: ClientAPI?

    init() {
        collecte = CollecteSante(lecteur: lecteur)
        dernierEnvoi = reglages.object(forKey: "sante.dernier_envoi") as? Date
        if let codes = reglages.stringArray(forKey: "sante.lues") {
            var cochees = Set(codes.compactMap(Donnee.init(rawValue:)))
            // « fcRepos » est devenue « frequence » ; les cases du détail arrivent cochées.
            if !reglages.bool(forKey: "sante.lues.detail") {
                if codes.contains("fcRepos") { cochees.insert(.frequence) }
                cochees.formUnion(Donnee.ajouteesAuDetail)
                reglages.set(true, forKey: "sante.lues.detail")
            }
            lues = cochees
        }
        Self.actuel = self
    }

    /// Une journée réduite à ce qui est coché.
    private func filtree(_ jour: JourSante) -> JourSante {
        var j = jour
        if !lues.contains(.pas) { j.pas = nil }
        if !lues.contains(.frequence) { j.fcRepos = nil }
        if !lues.contains(.vfc) { j.vfcMs = nil }
        if !lues.contains(.sommeil) { j.sommeilMinutes = nil }
        return j
    }

    var disponible: Bool { LecteurSante.disponible }

    nonisolated static func instant(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.timeZone = .current
        return format.string(from: date)
    }

    private static func jour(_ date: Date) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }

    /// La première fois, quatorze jours. Ensuite, depuis le dernier envoi
    /// réussi, avec deux jours de marge : une nuit arrive parfois tard dans Santé.
    private func debutDeLEnvoi() -> Date {
        let calendrier = Calendar.current
        let aujourdhui = calendrier.startOfDay(for: .now)
        guard let dernierEnvoi else {
            return calendrier.date(byAdding: .day, value: -13, to: aujourdhui) ?? aujourdhui
        }
        let depuis = calendrier.date(byAdding: .day, value: -2, to: calendrier.startOfDay(for: dernierEnvoi))
            ?? aujourdhui
        let plancher = calendrier.date(byAdding: .day, value: -30, to: aujourdhui) ?? aujourdhui
        return max(depuis, plancher)
    }

    /// iOS ne dit jamais si la lecture est refusée : une donnée refusée
    /// ressemble à une donnée absente. Le premier envoi suit la réponse.
    func demanderAcces() async {
        guard disponible else { return }
        try? await lecteur.demanderAcces()
        let avant = accesDemande
        await relireLAcces()
        if !avant && accesDemande {
            dernierEssai = nil
            await aLOuverture()
        }
    }

    func relireLAcces() async {
        accesDemande = !disponible ? true : await lecteur.accesDejaDemande()
    }

    /// À l'ouverture : un envoi si le dernier essai date de plus d'un quart d'heure.
    func aLOuverture() async {
        Self.planifier()
        await relireLAcces()
        guard accesDemande else { return }
        await relireLaFrequence()
        if let dernierEssai, Date.now.timeIntervalSince(dernierEssai) < 15 * 60 { return }
        await envoyer(raison: "ouverture")
    }

    func relireLaFrequence() async {
        guard disponible, lues.contains(.frequence) else {
            frequenceDuJour = []
            return
        }
        frequenceDuJour = (try? await lecteur.frequenceDuJour()) ?? []
    }

    private func corps(_ valeur: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: valeur)
    }

    @discardableResult
    func envoyer(raison: String, budget: TimeInterval = 40) async -> String {
        guard !enCours else { return "Un envoi est déjà en cours." }
        guard disponible else { return "Santé n'est pas disponible sur cet appareil." }
        guard let client else { return "Pas de serveur." }
        guard accesDemande else { return "Santé n'est pas encore autorisée." }
        enCours = true
        dernierEssai = .now
        defer { enCours = false }

        let debut = debutDeLEnvoi()
        var jours = 0
        var seances = 0
        var echecs = 0
        var injoignable = false
        do {
            for jour in try await lecteur.jours(depuis: debut).map(filtree) where !jour.estVide {
                do {
                    try await client.envoyer("PUT", "donnees-sante/jours/\(Self.jour(jour.jour))",
                                             corps: corps(jour.corps))
                    jours += 1
                } catch let erreur as ErreurAPI where erreur.injoignable {
                    injoignable = true
                    break
                } catch {
                    echecs += 1
                }
            }
            if !injoignable && lues.contains(.seances) {
                for seance in try await lecteur.seances(depuis: debut) {
                    do {
                        try await client.envoyer("PUT", "donnees-sante/activites/\(seance.id.uuidString)",
                                                 corps: corps(seance.corps))
                        seances += 1
                    } catch let erreur as ErreurAPI where erreur.injoignable {
                        injoignable = true
                        break
                    } catch {
                        echecs += 1
                    }
                }
            }
        } catch {
            echecs += 1
        }

        // SAN-11 à SAN-16 : puis le détail, l'historique avançant dans le temps donné.
        if !injoignable {
            await collecte.avancer(lues: lues, client: client, jusqua: Date.now.addingTimeInterval(budget))
        }

        let bilan = "\(jours) jour(s) et \(seances) séance(s) envoyés (\(raison))"
        if !injoignable && echecs == 0 {
            dernierEnvoi = .now
            reglages.set(dernierEnvoi, forKey: "sante.dernier_envoi")
        }
        dernierBilan = injoignable ? "Serveur injoignable : envoi reporté" :
            echecs > 0 ? "\(bilan), \(echecs) échec(s)" : bilan
        return dernierBilan ?? bilan
    }

    // MARK: Arrière-plan

    /// iOS décide de l'heure, au plus tôt dans trois heures. Santé est illisible
    /// téléphone verrouillé : l'envoi à l'ouverture reste la voie sûre.
    nonisolated static func planifier() {
        let demande = BGAppRefreshTaskRequest(identifier: idTache)
        demande.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(demande)
    }

    func envoyerEnFond() async {
        Self.planifier()
        await relireLAcces()
        await envoyer(raison: "arrière-plan", budget: 15)
    }

    /// iPhone branché : l'historique avance tant qu'iOS le laisse faire.
    func avancerLHistorique() async -> Bool {
        await relireLAcces()
        guard disponible, accesDemande, let client else { return false }
        return await collecte.avancer(lues: lues, client: client, jusqua: .distantFuture)
    }
}
