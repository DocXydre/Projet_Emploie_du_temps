import CoreLocation
import Foundation
import HealthKit

// Tout le détail de Santé (SAN-11 à SAN-16) : les mesures d'une séance, son
// découpage, son tracé, le quotidien mesure par mesure, le sommeil par phases.
// Rien n'est calculé ici : chaque valeur part telle que Santé la donne, dans
// l'unité de sa grandeur sur le serveur (`grandeur_sante`).

/// Une mesure prise pendant une séance (SAN-11).
struct MesureDeSeance: Encodable, Sendable {
    let grandeur: String
    let debut: Date
    let fin: Date?
    let valeur: Double
}

/// Un morceau d'une séance : kilomètre, étape, tour ou pause (SAN-13).
struct SegmentDeSeance: Encodable, Sendable {
    let sorte: String
    let rang: Int
    let debut: Date
    let fin: Date
    var distanceM: Double? = nil
    var libelle: String? = nil
}

/// Un point du tracé (SAN-14).
struct PointDeTrace: Encodable, Sendable {
    let instant: Date
    let latitude: Double
    let longitude: Double
    let altitudeM: Double?
    let precisionM: Double?
    let vitesseMs: Double?
}

/// Une mesure du quotidien, avec sa source (SAN-15).
struct EchantillonSante: Encodable, Sendable {
    let cle: String
    let grandeur: String
    let debut: Date
    let fin: Date?
    let valeur: Double
    let source: String?
    let appareil: String?
}

/// Une phase du sommeil (SAN-16).
struct PhaseDeSommeil: Encodable, Sendable {
    let cle: String
    let phase: String
    let debut: Date
    let fin: Date
    let source: String?
    let appareil: String?
}

/// Un type de Santé et la grandeur qu'il devient sur le serveur.
struct GrandeurLue: Sendable {
    let type: HKQuantityTypeIdentifier
    let grandeur: String
    let unite: HKUnit
    /// SpO2 : Santé donne une fraction, le serveur attend un pourcentage.
    var facteur: Double = 1

    func valeur(_ quantite: HKQuantity) -> Double {
        quantite.doubleValue(for: unite) * facteur
    }
}

extension LecteurSante {
    static let bpm = HKUnit.count().unitDivided(by: .minute())

    /// SAN-11 : ce que la montre mesure pendant une séance. La cadence se
    /// déduit des pas de chaque intervalle.
    static let grandeursDeSeance: [GrandeurLue] = [
        GrandeurLue(type: .heartRate, grandeur: "fc", unite: bpm),
        GrandeurLue(type: .runningSpeed, grandeur: "vitesse", unite: .meter().unitDivided(by: .second())),
        GrandeurLue(type: .runningPower, grandeur: "puissance", unite: .watt()),
        GrandeurLue(type: .runningStrideLength, grandeur: "foulee", unite: .meter()),
        GrandeurLue(type: .runningGroundContactTime, grandeur: "contact_sol", unite: .secondUnit(with: .milli)),
        GrandeurLue(type: .runningVerticalOscillation, grandeur: "oscillation", unite: .meterUnit(with: .centi)),
        GrandeurLue(type: .distanceWalkingRunning, grandeur: "distance", unite: .meter()),
        GrandeurLue(type: .activeEnergyBurned, grandeur: "energie", unite: .kilocalorie()),
    ]

    /// Ce qu'il faut lire en plus pour le détail : les types des séances, le
    /// tracé, et ceux du quotidien.
    static var typesDuDetail: Set<HKObjectType> {
        var types = Set<HKObjectType>(grandeursDeSeance.map { HKQuantityType($0.type) })
        types.insert(HKQuantityType(.stepCount))
        types.insert(HKSeriesType.workoutRoute())
        for flux in FluxSante.allCases {
            for grandeur in flux.grandeurs { types.insert(HKQuantityType(grandeur.type)) }
        }
        return types
    }

    // MARK: Une séance

    /// SAN-11 : les mesures prises entre le début et la fin de la séance, une
    /// par une, telles que Santé les garde.
    func mesures(de seance: HKWorkout) async -> [MesureDeSeance] {
        let periode = HKQuery.predicateForSamples(withStart: seance.startDate, end: seance.endDate,
                                                  options: [])
        var mesures: [MesureDeSeance] = []
        for grandeur in Self.grandeursDeSeance {
            let requete = HKQuantitySeriesSampleQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(grandeur.type), predicate: periode),
                options: .orderByQuantitySampleStartDate)
            do {
                for try await point in requete.results(for: store) {
                    let intervalle = point.dateInterval
                    mesures.append(MesureDeSeance(
                        grandeur: grandeur.grandeur, debut: intervalle.start,
                        fin: intervalle.duration > 0 ? intervalle.end : nil,
                        valeur: grandeur.valeur(point.quantity)))
                }
            } catch {
                continue
            }
        }
        // La cadence : les pas d'un intervalle, ramenés à la minute.
        let pas = HKQuantitySeriesSampleQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: periode),
            options: .orderByQuantitySampleStartDate)
        do {
            for try await point in pas.results(for: store) where point.dateInterval.duration >= 1 {
                let parMinute = point.quantity.doubleValue(for: .count()) / (point.dateInterval.duration / 60)
                mesures.append(MesureDeSeance(grandeur: "cadence", debut: point.dateInterval.start,
                                              fin: point.dateInterval.end, valeur: parMinute))
            }
        } catch {
            // Pas de pas lisibles : pas de cadence.
        }
        return mesures
    }

    /// SAN-13 : les étapes (les activités d'une séance en plusieurs parties,
    /// sinon ses segments), les tours, les pauses. Les kilomètres se déduisent
    /// des distances, à l'envoi.
    func decoupage(de seance: HKWorkout) -> [SegmentDeSeance] {
        var segments: [SegmentDeSeance] = []
        let activites = seance.workoutActivities
        let distance = HKQuantityType(.distanceWalkingRunning)
        if activites.count > 1 {
            for (rang, activite) in activites.enumerated() {
                let fin = activite.endDate ?? seance.endDate
                guard fin > activite.startDate else { continue }
                var etape = SegmentDeSeance(sorte: "etape", rang: rang + 1, debut: activite.startDate, fin: fin)
                etape.distanceM = activite.statistics(for: distance)?.sumQuantity()?.doubleValue(for: .meter())
                segments.append(etape)
            }
        }
        var tours = 0, etapes = 0, pauses = 0
        var debutDeLaPause: Date?
        for evenement in (seance.workoutEvents ?? []).sorted(by: { $0.dateInterval.start < $1.dateInterval.start }) {
            let intervalle = evenement.dateInterval
            switch evenement.type {
            case .lap where intervalle.duration > 0:
                tours += 1
                segments.append(SegmentDeSeance(sorte: "tour", rang: tours, debut: intervalle.start,
                                                fin: intervalle.end))
            case .segment where activites.count <= 1 && intervalle.duration > 0:
                etapes += 1
                segments.append(SegmentDeSeance(sorte: "etape", rang: etapes, debut: intervalle.start,
                                                fin: intervalle.end))
            case .pause, .motionPaused:
                debutDeLaPause = debutDeLaPause ?? intervalle.start
            case .resume, .motionResumed:
                if let debut = debutDeLaPause, intervalle.start > debut {
                    pauses += 1
                    segments.append(SegmentDeSeance(sorte: "pause", rang: pauses, debut: debut,
                                                    fin: intervalle.start))
                }
                debutDeLaPause = nil
            default:
                break
            }
        }
        return segments
    }

    /// SAN-13 : les kilomètres, à partir des distances de la séance.
    static func kilometres(_ mesures: [MesureDeSeance], debut: Date) -> [SegmentDeSeance] {
        var kilometres: [SegmentDeSeance] = []
        var cumul = 0.0
        var depart = debut
        for mesure in mesures where mesure.grandeur == "distance" {
            let fin = mesure.fin ?? mesure.debut
            cumul += mesure.valeur
            while cumul >= Double(kilometres.count + 1) * 1000 {
                // Le passage au kilomètre, au prorata de la mesure qui le franchit.
                let depasse = cumul - Double(kilometres.count + 1) * 1000
                let part = mesure.valeur > 0 ? 1 - depasse / mesure.valeur : 1
                let passage = mesure.debut.addingTimeInterval(fin.timeIntervalSince(mesure.debut) * part)
                guard passage > depart else { break }
                kilometres.append(SegmentDeSeance(sorte: "kilometre", rang: kilometres.count + 1,
                                                  debut: depart, fin: passage, distanceM: 1000))
                depart = passage
            }
        }
        return kilometres
    }

    /// SAN-14 : le tracé, point par point.
    func trace(de seance: HKWorkout) async -> [PointDeTrace] {
        let requete = HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: seance))],
            sortDescriptors: [])
        guard let routes = try? await requete.result(for: store) else { return [] }
        var points: [PointDeTrace] = []
        for route in routes {
            do {
                for try await lieu in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
                    points.append(PointDeTrace(
                        instant: lieu.timestamp,
                        latitude: lieu.coordinate.latitude, longitude: lieu.coordinate.longitude,
                        altitudeM: lieu.verticalAccuracy >= 0 ? lieu.altitude : nil,
                        precisionM: lieu.horizontalAccuracy >= 0 ? lieu.horizontalAccuracy : nil,
                        vitesseMs: lieu.speed >= 0 ? lieu.speed : nil))
                }
            } catch {
                continue
            }
        }
        return points
    }

    // MARK: Par ancre

    /// Les séances arrivées depuis l'ancre, au plus `limite`. Une ancre vide
    /// rend tout l'historique, par morceaux.
    func seances(apres ancre: HKQueryAnchor?, limite: Int) async throws
        -> (seances: [HKWorkout], ancre: HKQueryAnchor) {
        let requete = HKAnchoredObjectQueryDescriptor(predicates: [.workout()], anchor: ancre, limit: limite)
        let resultat = try await requete.result(for: store)
        return (resultat.addedSamples, resultat.newAnchor)
    }

    /// SAN-15 : les mesures d'un type arrivées depuis l'ancre.
    func echantillons(_ grandeur: GrandeurLue, apres ancre: HKQueryAnchor?, limite: Int) async throws
        -> (echantillons: [EchantillonSante], ancre: HKQueryAnchor, dernier: Date?) {
        let requete = HKAnchoredObjectQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(grandeur.type))], anchor: ancre, limit: limite)
        let resultat = try await requete.result(for: store)
        let lignes = resultat.addedSamples.map { e in
            EchantillonSante(cle: e.uuid.uuidString, grandeur: grandeur.grandeur, debut: e.startDate,
                             fin: e.endDate > e.startDate ? e.endDate : nil,
                             valeur: grandeur.valeur(e.quantity),
                             source: e.sourceRevision.source.name, appareil: e.device?.model)
        }
        return (lignes, resultat.newAnchor, resultat.addedSamples.map(\.endDate).max())
    }

    /// SAN-16 : les phases du sommeil arrivées depuis l'ancre.
    func phasesDeSommeil(apres ancre: HKQueryAnchor?, limite: Int) async throws
        -> (phases: [PhaseDeSommeil], ancre: HKQueryAnchor, dernier: Date?) {
        let requete = HKAnchoredObjectQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis))], anchor: ancre, limit: limite)
        let resultat = try await requete.result(for: store)
        let lignes = resultat.addedSamples.compactMap { e -> PhaseDeSommeil? in
            guard let phase = Self.phase(e.value), e.endDate > e.startDate else { return nil }
            return PhaseDeSommeil(cle: e.uuid.uuidString, phase: phase, debut: e.startDate, fin: e.endDate,
                                  source: e.sourceRevision.source.name, appareil: e.device?.model)
        }
        return (lignes, resultat.newAnchor, resultat.addedSamples.map(\.endDate).max())
    }

    static func phase(_ valeur: Int) -> String? {
        switch HKCategoryValueSleepAnalysis(rawValue: valeur) {
        case .inBed: "au_lit"
        case .asleepUnspecified: "endormi"
        case .awake: "eveille"
        case .asleepCore: "leger"
        case .asleepDeep: "profond"
        case .asleepREM: "paradoxal"
        default: nil
        }
    }

    /// Combien de séances Santé garde en tout : la mesure de l'avancée.
    func nombreDeSeances() async -> Int? {
        let requete = HKSampleQueryDescriptor(predicates: [.workout()], sortDescriptors: [])
        return try? await requete.result(for: store).count
    }

    /// La plus ancienne séance : le début de l'historique.
    func premiereSeance() async -> Date? {
        let requete = HKSampleQueryDescriptor(predicates: [.workout()],
                                              sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
                                              limit: 1)
        return try? await requete.result(for: store).first?.startDate
    }
}

/// SAN-15 : le quotidien, regroupé comme les cases de Réglages (5.10).
enum FluxSante: String, CaseIterable, Sendable {
    case frequence, forme, poids, nuit, energie

    var grandeurs: [GrandeurLue] {
        let bpm = LecteurSante.bpm
        switch self {
        case .frequence:
            return [GrandeurLue(type: .heartRate, grandeur: "fc", unite: bpm),
                    GrandeurLue(type: .restingHeartRate, grandeur: "fc_repos", unite: bpm)]
        case .forme:
            return [GrandeurLue(type: .heartRateVariabilitySDNN, grandeur: "vfc", unite: .secondUnit(with: .milli)),
                    GrandeurLue(type: .vo2Max, grandeur: "vo2max",
                                unite: HKUnit.literUnit(with: .milli)
                                    .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))),
                    GrandeurLue(type: .heartRateRecoveryOneMinute, grandeur: "fc_recuperation", unite: bpm)]
        case .poids:
            return [GrandeurLue(type: .bodyMass, grandeur: "poids", unite: .gramUnit(with: .kilo))]
        case .nuit:
            return [GrandeurLue(type: .oxygenSaturation, grandeur: "spo2", unite: .percent(), facteur: 100),
                    GrandeurLue(type: .respiratoryRate, grandeur: "respiration", unite: bpm),
                    GrandeurLue(type: .appleSleepingWristTemperature, grandeur: "temperature_poignet",
                                unite: .degreeCelsius())]
        case .energie:
            return [GrandeurLue(type: .activeEnergyBurned, grandeur: "energie", unite: .kilocalorie())]
        }
    }
}
