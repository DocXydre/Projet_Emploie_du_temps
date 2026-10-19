#if DEBUG && targetEnvironment(simulator)
import CoreLocation
import Foundation
import HealthKit

/// Pour essayer la collecte dans le simulateur, qui n'a ni montre ni Santé
/// remplie : une course fractionnée inventée, avec ses mesures, ses étapes et
/// son tracé, trois jours de quotidien et deux nuits. Tout est inventé, et ce
/// fichier n'existe que dans le simulateur : sur un iPhone, l'appli n'écrit
/// rien dans Santé (SAN-10).
enum RemplissageSante {
    static let montre = HKDevice(name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch",
                                 hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                                 localIdentifier: nil, udiDeviceIdentifier: nil)

    private static let ecrits: Set<HKSampleType> = [
        HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
        HKQuantityType(.heartRate), HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.runningSpeed), HKQuantityType(.runningPower),
        HKQuantityType(.runningStrideLength), HKQuantityType(.runningGroundContactTime),
        HKQuantityType(.runningVerticalOscillation), HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.stepCount), HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.vo2Max),
        HKQuantityType(.bodyMass), HKQuantityType(.oxygenSaturation),
        HKQuantityType(.respiratoryRate), HKCategoryType(.sleepAnalysis),
    ]

    static func remplir(_ store: HKHealthStore, lus: Set<HKObjectType>) async throws -> String {
        try await store.requestAuthorization(toShare: ecrits, read: lus)
        let course = try await fractionne(store)
        let quotidien = try await jours(store)
        return "Santé remplie : une course (\(course)), \(quotidien) mesures et deux nuits."
    }

    private static func q(_ type: HKQuantityTypeIdentifier, _ valeur: Double, _ unite: HKUnit,
                          _ debut: Date, _ fin: Date? = nil, appareil: HKDevice? = montre) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(type), quantity: HKQuantity(unit: unite, doubleValue: valeur),
                         start: debut, end: fin ?? debut, device: appareil, metadata: nil)
    }

    /// 6 × 400 m, hier à 18 h 32, autour d'un parc inventé.
    private static func fractionne(_ store: HKHealthStore) async throws -> String {
        let debut = Calendar.current.date(bySettingHour: 18, minute: 32, second: 0,
                                          of: Date.now.addingTimeInterval(-86_400)) ?? .now
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        let constructeur = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: montre)
        try await constructeur.beginCollection(at: debut)

        // Les étapes : (durée en s, allure en s/km, FC visée).
        var etapes: [(Int, Double, Double)] = [(900, 401, 136)]
        for k in 1...6 {
            etapes.append((k == 6 ? 118 : 110, k == 6 ? 295 : 275, 171))
            if k < 6 { etapes.append((94, 470, 142)) }
        }
        etapes.append((612, 425, 131))

        let bpm = HKUnit.count().unitDivided(by: .minute())
        var echantillons: [HKSample] = []
        var lieux: [CLLocation] = []
        var t = debut
        var fc = 118.0
        var parcouru = 0.0
        for (duree, allure, cible) in etapes {
            let fin = t.addingTimeInterval(TimeInterval(duree))
            let activite = HKWorkoutActivity(workoutConfiguration: configuration, start: t, end: fin, metadata: nil)
            try await constructeur.addWorkoutActivity(activite)
            let vitesse = 1000 / allure
            let rapide = allure < 300
            var x = t
            while x < fin {
                let suivant = min(x.addingTimeInterval(5), fin)
                fc += (cible - fc) * 0.12
                echantillons += [
                    q(.heartRate, fc.rounded(), bpm, x),
                    q(.distanceWalkingRunning, vitesse * suivant.timeIntervalSince(x), .meter(), x, suivant),
                    q(.runningSpeed, vitesse, .meter().unitDivided(by: .second()), x, suivant),
                    q(.runningPower, rapide ? 341 : 248, .watt(), x, suivant),
                    q(.runningStrideLength, rapide ? 1.38 : 1.05, .meter(), x, suivant),
                    q(.runningGroundContactTime, rapide ? 214 : 256, .secondUnit(with: .milli), x, suivant),
                    q(.runningVerticalOscillation, 8.9, .meterUnit(with: .centi), x, suivant),
                    q(.stepCount, (rapide ? 186 : 168) * suivant.timeIntervalSince(x) / 60, .count(), x, suivant),
                    q(.activeEnergyBurned, 0.9 * suivant.timeIntervalSince(x) / 5, .kilocalorie(), x, suivant),
                ]
                parcouru += vitesse * suivant.timeIntervalSince(x)
                let angle = parcouru / 2600 * 2 * .pi
                lieux.append(CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: 48.6952 + 0.0012 * sin(angle),
                                                       longitude: 6.1842 + 0.0019 * cos(angle)),
                    altitude: 205 + 6 * sin(parcouru / 400), horizontalAccuracy: 4, verticalAccuracy: 3,
                    course: -1, speed: vitesse, timestamp: x))
                x = suivant
            }
            t = fin
        }
        for paquet in echantillons.paquets(2000) {
            try await constructeur.addSamples(paquet)
        }
        // Une pause d'une minute pendant le retour au calme.
        try await constructeur.addWorkoutEvents([
            HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: t.addingTimeInterval(-300), duration: 0),
                           metadata: nil),
            HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: t.addingTimeInterval(-240), duration: 0),
                           metadata: nil),
        ])
        try await constructeur.endCollection(at: t)
        guard let seance = try await constructeur.finishWorkout() else { return "pas enregistrée" }

        let route = HKWorkoutRouteBuilder(healthStore: store, device: montre)
        try await route.insertRouteData(lieux)
        _ = try await route.finishRoute(with: seance, metadata: nil)
        return "\(echantillons.count) mesures, \(etapes.count) étapes, \(lieux.count) points"
    }

    /// Trois jours de FC, la VFC, la VO2max, un poids de la balance, la SpO2,
    /// la respiration, et deux nuits par phases.
    private static func jours(_ store: HKHealthStore) async throws -> Int {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let balance = HKDevice(name: "Balance", manufacturer: "Withings", model: "Body+", hardwareVersion: nil,
                               firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil,
                               udiDeviceIdentifier: nil)
        var echantillons: [HKSample] = []
        let jour = Calendar.current.startOfDay(for: .now)
        for k in 1...3 {
            let d = jour.addingTimeInterval(-Double(k) * 86_400)
            for m in stride(from: 7 * 60, to: 23 * 60, by: 15) {
                echantillons.append(q(.heartRate, 64 + 10 * sin(Double(m) / 95), bpm, d.addingTimeInterval(Double(m) * 60)))
            }
            echantillons += [
                q(.restingHeartRate, 52, bpm, d.addingTimeInterval(8 * 3600)),
                q(.heartRateVariabilitySDNN, 55 + Double(k), .secondUnit(with: .milli), d.addingTimeInterval(3 * 3600)),
                q(.oxygenSaturation, 0.96, .percent(), d.addingTimeInterval(4 * 3600)),
                q(.respiratoryRate, 14.2, bpm, d.addingTimeInterval(4 * 3600)),
            ]
        }
        let mlkgmin = HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        echantillons.append(q(.vo2Max, 47.3, mlkgmin, jour.addingTimeInterval(-86_400 + 19 * 3600)))
        echantillons.append(q(.bodyMass, 72.4, .gramUnit(with: .kilo), jour.addingTimeInterval(-2 * 86_400 + 7 * 3600),
                              appareil: balance))

        // Deux nuits, de 23 h 28 à 7 h 02.
        let phases: [(HKCategoryValueSleepAnalysis, Int)] = [
            (.asleepCore, 22), (.asleepDeep, 48), (.asleepCore, 30), (.asleepREM, 14), (.asleepCore, 52),
            (.asleepDeep, 30), (.awake, 4), (.asleepCore, 60), (.asleepREM, 32), (.asleepCore, 92),
            (.asleepREM, 50), (.awake, 20)]
        for k in 1...2 {
            var t = jour.addingTimeInterval(-Double(k) * 86_400 - 32 * 60)
            for (phase, minutes) in phases {
                let fin = t.addingTimeInterval(Double(minutes) * 60)
                echantillons.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: phase.rawValue,
                                                     start: t, end: fin, device: montre, metadata: nil))
                t = fin
            }
        }
        try await store.save(echantillons)
        return echantillons.count
    }
}
#endif
