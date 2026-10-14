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

    /// SAN-10 : ce que l'appli lit, coché dans Réglages. Tout l'est au départ.
    enum Donnee: String, CaseIterable, Identifiable {
        case pas, fcRepos, vfc, sommeil, seances, frequence

        var id: String { rawValue }

        var libelle: String {
            switch self {
            case .pas: "Pas"
            case .fcRepos: "Fréquence cardiaque au repos"
            case .vfc: "Variabilité cardiaque"
            case .sommeil: "Sommeil"
            case .seances: "Séances de la montre"
            case .frequence: "Fréquence cardiaque du jour"
            }
        }

        var icone: String {
            switch self {
            case .pas: "figure.walk"
            case .fcRepos: "heart"
            case .vfc: "waveform.path.ecg"
            case .sommeil: "bed.double"
            case .seances: "applewatch"
            case .frequence: "heart.text.square"
            }
        }
    }

    /// Ce qui est coché. Une case décochée n'est plus envoyée ; ce qui est déjà
    /// sur le serveur y reste.
    var lues: Set<Donnee> = Set(Donnee.allCases) {
        didSet { reglages.set(lues.map(\.rawValue), forKey: "sante.lues") }
    }

    private(set) var enCours = false
    private(set) var dernierEnvoi: Date?
    private(set) var dernierBilan: String?
    private(set) var frequenceDuJour: [PointSerie] = []

    let lecteur = LecteurSante()
    private let reglages = UserDefaults.standard
    private var dernierEssai: Date?
    var client: ClientAPI?

    init() {
        dernierEnvoi = reglages.object(forKey: "sante.dernier_envoi") as? Date
        if let codes = reglages.stringArray(forKey: "sante.lues") {
            lues = Set(codes.compactMap(Donnee.init(rawValue:)))
        }
    }

    /// Une journée réduite à ce qui est coché.
    private func filtree(_ jour: JourSante) -> JourSante {
        var j = jour
        if !lues.contains(.pas) { j.pas = nil }
        if !lues.contains(.fcRepos) { j.fcRepos = nil }
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
    /// ressemble à une donnée absente.
    func demanderAcces() async {
        guard disponible else { return }
        try? await lecteur.demanderAcces()
    }

    /// À l'ouverture : un envoi si le dernier essai date de plus d'un quart d'heure.
    func aLOuverture() async {
        Self.planifier()
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
    func envoyer(raison: String) async -> String {
        guard !enCours else { return "Un envoi est déjà en cours." }
        guard disponible else { return "Santé n'est pas disponible sur cet appareil." }
        guard let client else { return "Pas de serveur." }
        enCours = true
        dernierEssai = .now
        defer { enCours = false }
        await demanderAcces()

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
        await envoyer(raison: "arrière-plan")
    }
}
