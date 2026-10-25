import CoreLocation
import Foundation
import Observation

/// POS-1 à POS-6 : l'iPhone surveille un cercle autour de chaque lieu connu,
/// même appli fermée, et dit au serveur où il est. Rien d'autre : pas de suivi
/// continu, pas de tracé. À chaque entrée, chaque sortie et chaque ouverture de
/// l'appli, un relevé précis part au serveur, qui trouve le lieu (POS-3).
///
/// Réveillée par iOS pour un passage de cercle, l'appli n'a que quelques
/// secondes : sans relevé à temps, elle envoie le centre du lieu où elle entre,
/// ou le seul nom du lieu dont elle sort.
///
/// Les cercles sont ceux de `CLLocationManager`, pas de `CLMonitor` : sur le
/// simulateur d'iOS 27, `CLMonitor` laisse chaque cercle « unmonitored », faute
/// de pouvoir les garder (persistenceUnavailable). La surveillance de régions
/// classique relance l'appli de la même façon.
///
/// En secours, les changements de position importants d'iOS (environ 500 m) :
/// ils relancent aussi l'appli, et voient un départ en voiture même quand un
/// cercle a manqué son passage. Une position n'est envoyée que si l'on a bougé
/// de 200 m, ou toutes les vingt minutes au plus.
@MainActor
@Observable
final class SuiviPosition: NSObject {
    static let partage = SuiviPosition()

    /// Un lieu connu, tel que `GET /appli/lieux` le rend (ADR-1).
    struct Lieu: Decodable, Sendable, Identifiable, Hashable {
        var idLieuConnu: Int
        var nom: String
        var nature: String
        var adresse: String
        var latitude: Double
        var longitude: Double
        var rayonM: Int
        var commun: Bool
        var modeTrajet: String
        var description: String?
        var lieuxDeSport: [String]?
        var trajetsDepuis: [Trajet]?

        var id: Int { idLieuConnu }
    }

    struct Trajet: Decodable, Sendable, Hashable {
        var depuis: String
        var minutes: Int
        var mode: String
        var estime: Bool
    }

    /// Où le serveur me croit (POS-6).
    struct Etat: Decodable, Sendable {
        var sue: Bool
        var lieu: String?
        var depuis: Date?
        var autorisation: String
        var precise: Bool
    }

    private struct Lieux: Decodable, Sendable {
        var lieux: [Lieu]
        var position: Etat
    }

    private struct Envoi: Encodable {
        var latitude: Double?
        var longitude: Double?
        var precisionM: Double?
        var instant: Date
        var autorisation: String
        var precise: Bool
        var sortieDe: Int?
    }

    /// iOS ne surveille pas plus de vingt cercles par appli (POS-2).
    static let cerclesAuPlus = 20
    /// POS-3 : au-delà, le serveur ne s'en sert pas ; inutile d'attendre mieux.
    private static let precisionVoulue: CLLocationAccuracy = 100

    private(set) var autorisation: CLAuthorizationStatus = .notDetermined
    private(set) var precise = false
    private(set) var lieux: [Lieu] = []
    private(set) var etat: Etat?

    var client: ClientAPI? {
        didSet {
            guard client != nil else { lieux = []; etat = nil; return }
            Task { await demarrer() }
        }
    }

    @ObservationIgnored private let gestionnaire = CLLocationManager()
    @ObservationIgnored private var sessionDeService: CLServiceSession?
    @ObservationIgnored private var demarrage = false
    @ObservationIgnored private var aRefaire = false
    @ObservationIgnored private var dernierEnvoye: CLLocation?

    override init() {
        super.init()
        gestionnaire.delegate = self
        lireAutorisation()
    }

    /// POS-1 : en marche avec « Toujours » et la position exacte.
    var enMarche: Bool { autorisation == .authorizedAlways && precise }

    private var autorisationPourLeServeur: String {
        switch autorisation {
        case .authorizedAlways: "toujours"
        case .authorizedWhenInUse: "utilisation"
        case .denied, .restricted: "refusee"
        default: "inconnue"
        }
    }

    /// Le bouton de Réglages, Lieux : la première demande, puis « Toujours ».
    /// Refusée, seule l'appli Réglages d'iOS peut la rendre.
    func activer() {
        switch autorisation {
        case .notDetermined: gestionnaire.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: gestionnaire.requestAlwaysAuthorization()
        default: break
        }
    }

    private func lireAutorisation() {
        autorisation = gestionnaire.authorizationStatus
        precise = gestionnaire.accuracyAuthorization == .fullAccuracy
    }

    /// À l'ouverture de l'appli et au réveil : les cercles à jour, un relevé,
    /// et un signe de vie pour le serveur (POS-6), même sans autorisation.
    func demarrer() async {
        guard client != nil else { return }
        // Un démarrage demandé pendant un autre (l'autorisation arrive juste après
        // le lancement) se refait à la fin du premier, au lieu de se perdre.
        guard !demarrage else { aRefaire = true; return }
        demarrage = true
        defer {
            demarrage = false
            if aRefaire {
                aRefaire = false
                Task { await demarrer() }
            }
        }
        lireAutorisation()
        guard autorisation == .authorizedAlways || autorisation == .authorizedWhenInUse else {
            await envoyer(Envoi(instant: .now, autorisation: autorisationPourLeServeur,
                                precise: precise))
            return
        }
        if autorisation == .authorizedAlways, sessionDeService == nil {
            sessionDeService = CLServiceSession(authorization: .always)
        }
        if autorisation == .authorizedAlways {
            gestionnaire.startMonitoringSignificantLocationChanges()
        }
        await rafraichirLesCercles()
        await releverEtEnvoyer()
    }

    /// Les lieux du serveur deviennent les cercles surveillés, les plus proches du
    /// foyer d'abord. Un cercle ajouté sous le même nom remplace l'ancien.
    func rafraichirLesCercles() async {
        guard let client, let lu: Lieux = try? await client.requete("GET", "appli/lieux") else { return }
        etat = lu.position
        let foyer = lu.lieux.first { $0.nature == "foyer" }
        let ranges = lu.lieux.sorted { a, b in
            guard let foyer else { return a.idLieuConnu < b.idLieuConnu }
            return Self.distance(a, foyer) < Self.distance(b, foyer)
        }
        lieux = lu.lieux
        guard autorisation == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let gardes = Array(ranges.prefix(Self.cerclesAuPlus))
        let voulus = Set(gardes.map { "lieu-\($0.idLieuConnu)" })
        for ancien in gestionnaire.monitoredRegions where !voulus.contains(ancien.identifier) {
            gestionnaire.stopMonitoring(for: ancien)
        }
        for lieu in gardes {
            // Un cercle ajouté sous le même nom remplace l'ancien.
            let cercle = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: lieu.latitude, longitude: lieu.longitude),
                radius: min(CLLocationDistance(lieu.rayonM), gestionnaire.maximumRegionMonitoringDistance),
                identifier: "lieu-\(lieu.idLieuConnu)")
            cercle.notifyOnEntry = true
            cercle.notifyOnExit = true
            gestionnaire.startMonitoring(for: cercle)
        }
    }

    private static func distance(_ a: Lieu, _ b: Lieu) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Un passage de cercle : un relevé si iOS en laisse le temps, sinon ce que
    /// l'on sait du lieu.
    fileprivate func recevoir(_ identifiant: String, entree: Bool) async {
        guard let id = Int(identifiant.replacingOccurrences(of: "lieu-", with: "")) else { return }
        if let releve = await relever() {
            await envoyer(depuis: releve)
            return
        }
        if entree, let lieu = lieux.first(where: { $0.idLieuConnu == id }) {
            await envoyer(Envoi(latitude: lieu.latitude, longitude: lieu.longitude, precisionM: 0,
                                instant: .now, autorisation: autorisationPourLeServeur,
                                precise: precise))
        } else if !entree {
            await envoyer(Envoi(instant: .now, autorisation: autorisationPourLeServeur,
                                precise: precise, sortieDe: id))
        }
    }

    func releverEtEnvoyer() async {
        if let releve = await relever() {
            await envoyer(depuis: releve)
        } else {
            await envoyer(Envoi(instant: .now, autorisation: autorisationPourLeServeur,
                                precise: precise))
        }
    }

    /// Le premier relevé assez précis, dix secondes au plus.
    private func relever() async -> CLLocation? {
        await withTaskGroup(of: CLLocation?.self) { groupe in
            groupe.addTask {
                do {
                    for try await maj in CLLocationUpdate.liveUpdates() {
                        if let lieu = maj.location, lieu.horizontalAccuracy >= 0,
                           lieu.horizontalAccuracy <= Self.precisionVoulue {
                            return lieu
                        }
                    }
                } catch {}
                return nil
            }
            groupe.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let premier = await groupe.next() ?? nil
            groupe.cancelAll()
            return premier
        }
    }

    /// Un changement important : envoyé seulement si l'on a bougé.
    fileprivate func changement(_ releve: CLLocation) async {
        if let dernier = dernierEnvoye, releve.distance(from: dernier) < 200,
           releve.timestamp.timeIntervalSince(dernier.timestamp) < 20 * 60 {
            return
        }
        await envoyer(depuis: releve)
    }

    private func envoyer(depuis releve: CLLocation) async {
        dernierEnvoye = releve
        await envoyer(Envoi(latitude: releve.coordinate.latitude,
                            longitude: releve.coordinate.longitude,
                            precisionM: releve.horizontalAccuracy, instant: releve.timestamp,
                            autorisation: autorisationPourLeServeur, precise: precise))
    }

    private func envoyer(_ envoi: Envoi) async {
        guard let client else { return }
        // Une position qui n'arrive pas n'est pas rejouée : la suivante la remplace.
        try? await client.envoyer("POST", "appli/position", corps: ClientAPI.corps(envoi))
        if let lu: Etat = try? await client.requete("GET", "appli/position") { etat = lu }
    }
}

extension SuiviPosition: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let derniere = locations.last, derniere.horizontalAccuracy >= 0 else { return }
        Task { @MainActor in await self.changement(derniere) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Une position manquée : la suivante la remplacera.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in await self.recevoir(id, entree: true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in await self.recevoir(id, entree: false) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let avant = self.autorisation
            self.lireAutorisation()
            // « Pendant l'utilisation » accordé : iOS propose ensuite « Toujours ».
            if avant == .notDetermined, self.autorisation == .authorizedWhenInUse {
                self.gestionnaire.requestAlwaysAuthorization()
            }
            await self.demarrer()
        }
    }
}
