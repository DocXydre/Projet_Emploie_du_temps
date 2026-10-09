import Foundation
import HealthKit

/// Une journée telle que la montre l'a vue. Une valeur absente reste absente :
/// ce n'est pas un zéro (SAN-5).
struct JourSante: Identifiable {
    let jour: Date
    var pas: Int?
    var fcRepos: Int?
    var vfcMs: Double?
    var sommeilMinutes: Int?

    var id: Date { jour }
    var estVide: Bool { pas == nil && fcRepos == nil && vfcMs == nil && sommeilMinutes == nil }

    /// Le corps de `PUT /donnees-sante/jours/{jour}` : seulement ce qui existe.
    var corps: [String: Any] {
        var c: [String: Any] = [:]
        if let pas { c["pas"] = pas }
        if let fcRepos { c["fc_repos"] = fcRepos }
        if let vfcMs { c["vfc_ms"] = (vfcMs * 10).rounded() / 10 }
        if let sommeilMinutes { c["sommeil_minutes"] = sommeilMinutes }
        return c
    }
}

/// Une séance enregistrée par la montre (SAN-2).
struct SeanceMontre: Identifiable {
    let id: UUID
    let type: String
    let libelle: String
    let debut: Date
    let fin: Date
    let dureeSecondes: Int
    var distanceM: Int?
    var deniveleM: Int?
    var energieKcal: Int?
    var fcMoyenne: Int?
    var fcMax: Int?
    var allureSKm: Int?
    var cadence: Int?
    var details: [String: Any] = [:]

    /// Le corps de `PUT /donnees-sante/activites/{cle}`. La discipline est
    /// déduite du type par le serveur.
    var corps: [String: Any] {
        var c: [String: Any] = [
            "type": type,
            "debut": Format.instant(debut),
            "fin": Format.instant(fin),
            "duree_secondes": max(dureeSecondes, 1),
            "details": details,
        ]
        if let distanceM { c["distance_m"] = distanceM }
        if let deniveleM { c["denivele_m"] = deniveleM }
        if let energieKcal { c["energie_kcal"] = energieKcal }
        if let fcMoyenne { c["fc_moyenne"] = fcMoyenne }
        if let fcMax, fcMax >= (fcMoyenne ?? 0) { c["fc_max"] = fcMax }
        if let allureSKm { c["allure_s_km"] = allureSKm }
        if let cadence { c["cadence"] = cadence }
        return c
    }
}

/// Tout ce qui lit l'application Santé. Rien n'y est écrit.
final class LecteurSante {
    let store = HKHealthStore()

    static var disponible: Bool { HKHealthStore.isHealthDataAvailable() }

    private var typesLus: Set<HKObjectType> {
        [
            HKQuantityType(.stepCount),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType(),
        ]
    }

    /// Ouvre la fenêtre d'autorisation de Santé. iOS ne dit jamais si la lecture
    /// a été refusée : une donnée refusée ressemble à une donnée absente.
    func demanderAcces() async throws {
        try await store.requestAuthorization(toShare: [], read: typesLus)
    }

    /// La date de la plus ancienne donnée de pas : le début de l'historique.
    func premiereDonnee() async throws -> Date? {
        let descripteur = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.stepCount))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: 1)
        return try await descripteur.result(for: store).first?.startDate
    }

    // MARK: - Les journées

    func jours(depuis debut: Date, jusqua fin: Date = Date()) async throws -> [JourSante] {
        let calendrier = Calendar.current
        let premier = calendrier.startOfDay(for: debut)
        let bpm = HKUnit.count().unitDivided(by: .minute())

        let pas = try await parJour(.stepCount, options: .cumulativeSum, du: premier, au: fin)
        let repos = try await parJour(.restingHeartRate, options: .discreteAverage, du: premier, au: fin)
        let vfc = try await parJour(.heartRateVariabilitySDNN, options: .discreteAverage,
                                    du: premier, au: fin)
        let sommeil = try await sommeilParJour(du: premier, au: fin)

        var resultat: [JourSante] = []
        var jour = premier
        while jour <= fin {
            var j = JourSante(jour: jour)
            if let s = pas[jour]?.sumQuantity() {
                j.pas = Int(s.doubleValue(for: .count()).rounded())
            }
            if let r = repos[jour]?.averageQuantity() {
                j.fcRepos = Int(r.doubleValue(for: bpm).rounded())
            }
            if let v = vfc[jour]?.averageQuantity() {
                j.vfcMs = v.doubleValue(for: .secondUnit(with: .milli))
            }
            j.sommeilMinutes = sommeil[jour]
            resultat.append(j)
            guard let suivant = calendrier.date(byAdding: .day, value: 1, to: jour) else { break }
            jour = suivant
        }
        return resultat
    }

    private func parJour(_ identifiant: HKQuantityTypeIdentifier, options: HKStatisticsOptions,
                         du debut: Date, au fin: Date) async throws -> [Date: HKStatistics] {
        let type = HKQuantityType(identifiant)
        let periode = HKQuery.predicateForSamples(withStart: debut, end: fin)
        let descripteur = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: periode),
            options: options,
            anchorDate: debut,
            intervalComponents: DateComponents(day: 1))
        let collection = try await descripteur.result(for: store)
        var parJour: [Date: HKStatistics] = [:]
        collection.enumerateStatistics(from: debut, to: fin) { statistiques, _ in
            parJour[Calendar.current.startOfDay(for: statistiques.startDate)] = statistiques
        }
        return parJour
    }

    /// Les minutes de sommeil de chaque nuit, rangées au jour du réveil. Une nuit
    /// qui finit après 18 h compte pour le lendemain. Les enregistrements de la
    /// montre et de l'iPhone se recouvrent : leurs intervalles sont fusionnés
    /// avant d'être comptés, pour ne rien compter deux fois.
    private func sommeilParJour(du debut: Date, au fin: Date) async throws -> [Date: Int] {
        let calendrier = Calendar.current
        let depuis = calendrier.date(byAdding: .hour, value: -12, to: debut) ?? debut
        let type = HKCategoryType(.sleepAnalysis)
        let descripteur = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type,
                                         predicate: HKQuery.predicateForSamples(withStart: depuis,
                                                                                end: fin))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let echantillons = try await descripteur.result(for: store)

        let endormi: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        var nuits: [Date: [(Date, Date)]] = [:]
        for e in echantillons where endormi.contains(e.value) {
            let reveil = calendrier.date(byAdding: .hour, value: 6, to: e.endDate) ?? e.endDate
            let jour = calendrier.startOfDay(for: reveil)
            guard jour >= debut else { continue }
            nuits[jour, default: []].append((e.startDate, e.endDate))
        }

        var minutes: [Date: Int] = [:]
        for (jour, intervalles) in nuits {
            let tries = intervalles.sorted { $0.0 < $1.0 }
            var total: TimeInterval = 0
            var courant = tries[0]
            for intervalle in tries.dropFirst() {
                if intervalle.0 <= courant.1 {
                    courant.1 = max(courant.1, intervalle.1)
                } else {
                    total += courant.1.timeIntervalSince(courant.0)
                    courant = intervalle
                }
            }
            total += courant.1.timeIntervalSince(courant.0)
            minutes[jour] = min(Int((total / 60).rounded()), 1440)
        }
        return minutes
    }

    // MARK: - Les séances

    func seances(depuis debut: Date) async throws -> [SeanceMontre] {
        let descripteur = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: debut, end: Date()))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)])
        let entrainements = try await descripteur.result(for: store)
        return entrainements.map { self.seance(de: $0) }
    }

    private func seance(de w: HKWorkout) -> SeanceMontre {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let interieur = (w.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false
        let (type, libelle) = TypesSeance.nom(w.workoutActivityType, interieur: interieur)

        var s = SeanceMontre(id: w.uuid, type: type, libelle: libelle, debut: w.startDate,
                             fin: w.endDate, dureeSecondes: Int(w.duration.rounded()))

        let frequence = w.statistics(for: HKQuantityType(.heartRate))
        if let moyenne = frequence?.averageQuantity() {
            s.fcMoyenne = Int(moyenne.doubleValue(for: bpm).rounded())
        }
        if let maximum = frequence?.maximumQuantity() {
            s.fcMax = Int(maximum.doubleValue(for: bpm).rounded())
        }
        if let energie = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
            s.energieKcal = Int(energie.doubleValue(for: .kilocalorie()).rounded())
        }

        var distance: Double?
        for identifiant in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling,
                            .distanceSwimming] {
            if let d = w.statistics(for: HKQuantityType(identifiant))?.sumQuantity() {
                distance = d.doubleValue(for: .meter())
                break
            }
        }
        if let distance, distance > 0 {
            s.distanceM = Int(distance.rounded())
            if type.lowercased().contains("running") || type == "walking" || type == "hiking" {
                s.allureSKm = Int((w.duration / (distance / 1000)).rounded())
            }
        }
        if let pas = w.statistics(for: HKQuantityType(.stepCount))?.sumQuantity(), w.duration > 60 {
            s.cadence = Int((pas.doubleValue(for: .count()) / (w.duration / 60)).rounded())
        }
        if let montee = w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
            s.deniveleM = Int(montee.doubleValue(for: .meter()).rounded())
        }

        // SAN-2 : ce que les colonnes ne nomment pas est gardé tel quel.
        var details: [String: Any] = [
            "interieur": interieur,
            "source": w.sourceRevision.source.name,
            "type_healthkit": Int(w.workoutActivityType.rawValue),
        ]
        if let appareil = w.device?.model { details["appareil"] = appareil }
        if let temperature = w.metadata?[HKMetadataKeyWeatherTemperature] as? HKQuantity {
            details["temperature_c"] = (temperature.doubleValue(for: .degreeCelsius()) * 10)
                .rounded() / 10
        }
        if let longueur = w.metadata?[HKMetadataKeyLapLength] as? HKQuantity {
            details["longueur_bassin_m"] = longueur.doubleValue(for: .meter())
        }
        s.details = details
        return s
    }
}

/// Le nom d'une séance pour le serveur (qui en déduit la discipline, dans
/// `api/coach/sante.py`) et pour l'écran.
enum TypesSeance {
    static func nom(_ type: HKWorkoutActivityType, interieur: Bool) -> (String, String) {
        switch type {
        case .running: return interieur ? ("running", "Course sur tapis") : ("running", "Course")
        case .traditionalStrengthTraining: return ("traditionalStrengthTraining", "Musculation")
        case .functionalStrengthTraining: return ("functionalStrengthTraining",
                                                  "Renforcement fonctionnel")
        case .coreTraining: return ("coreTraining", "Gainage")
        case .highIntensityIntervalTraining: return ("highIntensityIntervalTraining", "HIIT")
        case .elliptical: return ("elliptical", "Elliptique")
        case .rowing: return ("rowing", "Rameur")
        case .stairClimbing: return ("stairClimbing", "Escaliers")
        case .stairs: return ("stairs", "Escaliers")
        case .stepTraining: return ("stepper", "Stepper")
        case .cycling: return interieur ? ("indoorCycling", "Vélo d'intérieur")
                                        : ("cycling", "Vélo")
        case .mixedCardio: return ("mixedCardio", "Cardio")
        case .crossTraining: return ("crossTraining", "Cross training")
        case .swimming: return ("swimming", "Natation")
        case .walking: return ("walking", "Marche")
        case .hiking: return ("hiking", "Randonnée")
        case .yoga: return ("yoga", "Yoga")
        case .flexibility: return ("flexibility", "Souplesse")
        case .cooldown: return ("cooldown", "Retour au calme")
        default: return ("autre_\(type.rawValue)", "Autre activité")
        }
    }
}
