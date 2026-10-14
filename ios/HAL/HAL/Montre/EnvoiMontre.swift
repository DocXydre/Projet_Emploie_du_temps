import Foundation
import HealthKit
import WorkoutKit

/// MON-1 : une course ou une séance de cardio prévue part sur l'app Exercice de
/// l'Apple Watch, avec ses étapes et ses alertes. On la lance sur la montre ; à
/// la fin, elle arrive dans Santé et valide la séance prévue toute seule (MON-2).
enum EnvoiMontre {
    enum Echec: LocalizedError {
        case refuse
        case pasUneCourse

        var errorDescription: String? {
            switch self {
            case .refuse: "L'envoi à la montre n'est pas autorisé. Réglages d'iOS, HAL, Séances d'entraînement."
            case .pasUneCourse: "Seules les courses et les séances de cardio partent sur la montre."
            }
        }
    }

    /// Les séances déjà envoyées, pour le dire dans la séance prévue.
    static func dejaEnvoyee(_ id: Int) async -> Bool {
        let plans = await WorkoutScheduler.shared.scheduledWorkouts
        return plans.contains { $0.plan.id == identifiant(id) }
    }

    /// La séance, programmée à son heure dans l'app Exercice. La renvoyer remplace
    /// l'envoi précédent : son identifiant vient du numéro de la séance.
    static func envoyer(_ detail: DetailSeance) async throws {
        guard ["course", "cardio"].contains(detail.seance.discipline ?? "") else { throw Echec.pasUneCourse }
        let etat = await WorkoutScheduler.shared.requestAuthorization()
        guard etat == .authorized else { throw Echec.refuse }

        let plan = WorkoutPlan(.custom(seanceSurMesure(detail)), id: identifiant(detail.seance.idOccurrence))
        for deja in await WorkoutScheduler.shared.scheduledWorkouts where deja.plan.id == plan.id {
            await WorkoutScheduler.shared.remove(deja.plan, at: deja.date)
        }
        let quand = detail.seance.debut ?? detail.seance.jour ?? .now
        let composants = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: quand)
        await WorkoutScheduler.shared.schedule(plan, at: composants)
    }

    /// Un identifiant stable par séance : « HAL » puis le numéro de la séance.
    private static func identifiant(_ id: Int) -> UUID {
        let hex = String(format: "%012x", id)
        return UUID(uuidString: "4841C000-0000-4000-8000-\(hex)") ?? UUID()
    }

    // MARK: Les étapes

    static func seanceSurMesure(_ detail: DetailSeance) -> CustomWorkout {
        let course = detail.seance.discipline == "course"
        let zone = zoneCardiaque(detail.seance.intensite)
        let allure = allureVisee(detail)
        let duree = Double(detail.seance.dureeMinutes ?? 40)

        var blocs: [IntervalBlock] = []
        // Les lignes prévues par HAL : un bloc chacune, répété autant de fois que
        // de séries, avec la récupération entre deux.
        for ligne in detail.prevu {
            var etapes = [IntervalStep(.work, goal: objectif(ligne, defaut: duree), alert: alerte(allure, zone))]
            if let repos = ligne.reposSecondes, repos > 0 {
                etapes.append(IntervalStep(.recovery, goal: .time(Double(repos), .seconds)))
            }
            blocs.append(IntervalBlock(steps: etapes, iterations: max(1, ligne.series ?? 1)))
        }

        var echauffement: WorkoutStep?
        var retourAuCalme: WorkoutStep?
        if blocs.isEmpty {
            // Une séance sans détail : échauffement, le corps de la séance, retour au calme.
            let principal: WorkoutGoal
            if let distance = distanceVisee(detail) {
                principal = .distance(Double(distance), .meters)
            } else {
                principal = .time(max(10, duree - (duree >= 30 ? 15 : 0)), .minutes)
            }
            if duree >= 30 {
                echauffement = WorkoutStep(goal: .time(10, .minutes), alert: HeartRateZoneAlert(zone: 2))
                retourAuCalme = WorkoutStep(goal: .time(5, .minutes))
            }
            blocs = [IntervalBlock(steps: [IntervalStep(.work, goal: principal, alert: alerte(allure, zone))],
                                   iterations: 1)]
        }

        return CustomWorkout(activity: course ? .running : .mixedCardio,
                             location: course ? .outdoor : .indoor,
                             displayName: detail.titre,
                             warmup: echauffement,
                             blocks: blocs,
                             cooldown: retourAuCalme)
    }

    private static func objectif(_ ligne: LignePrevue, defaut: Double) -> WorkoutGoal {
        if let distance = ligne.distanceM, distance > 0 { return .distance(Double(distance), .meters) }
        if let secondes = ligne.dureeSecondes, secondes > 0 { return .time(Double(secondes), .seconds) }
        return .time(defaut, .minutes)
    }

    /// L'allure prime : quand HAL en donne une, la montre prévient si on s'en écarte.
    /// Sinon, la zone de fréquence cardiaque de l'intensité.
    private static func alerte(_ allure: Int?, _ zone: Int) -> (any WorkoutAlert)? {
        if let allure, allure > 0 {
            // ± 5 % autour de l'allure visée, en vitesse.
            let vitesse = 1000.0 / Double(allure)
            let bas = Measurement(value: vitesse * 0.95, unit: UnitSpeed.metersPerSecond)
            let haut = Measurement(value: vitesse * 1.05, unit: UnitSpeed.metersPerSecond)
            return SpeedRangeAlert(target: bas...haut, metric: .current)
        }
        return HeartRateZoneAlert(zone: zone)
    }

    private static func zoneCardiaque(_ intensite: String?) -> Int {
        switch intensite {
        case "legere": 2
        case "dure": 4
        default: 3
        }
    }

    /// « 6:30/km », « 6'30 /km » dans la consigne de HAL : des secondes au kilomètre.
    private static func allureVisee(_ detail: DetailSeance) -> Int? {
        let textes = [detail.seance.consigne] + detail.prevu.map(\.consigne)
        for texte in textes.compactMap({ $0 }) {
            if let trouve = texte.firstMatch(of: #/(\d{1,2})\s*[:'’]\s*(\d{2})\s*(?:min)?\s*/\s*km/#),
               let minutes = Int(trouve.1), let secondes = Int(trouve.2) {
                return minutes * 60 + secondes
            }
        }
        return nil
    }

    /// « Test 3 km », « 5 km » dans le titre ou la consigne : la distance à courir.
    private static func distanceVisee(_ detail: DetailSeance) -> Int? {
        let textes = [detail.titre, detail.seance.typeSeance, detail.seance.consigne]
        for texte in textes.compactMap({ $0 }) {
            if let trouve = texte.firstMatch(of: #/(\d+(?:[.,]\d+)?)\s*km/#),
               let km = Double(trouve.1.replacingOccurrences(of: ",", with: ".")) {
                return Int(km * 1000)
            }
        }
        return nil
    }
}
