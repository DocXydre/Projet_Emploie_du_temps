import BackgroundTasks
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// Les notifications envoyées par le serveur (NOT-16) : l'accord d'iOS, puis le
/// jeton de l'iPhone, enregistré auprès du serveur pour que les envois d'Apple
/// arrivent ici. Se déconnecter le retire (CNX-6).
///
/// PRE-2 : la fenêtre d'iOS ne s'ouvre qu'après l'écran qui explique, au
/// premier lancement, ou depuis Réglages.
@MainActor
@Observable
final class Notifications {
    enum Etat {
        /// iOS n'a encore rien demandé.
        case aDemander
        case autorisees
        /// Refusées : seul l'écran des réglages d'iOS peut les rallumer.
        case refusees
    }

    private(set) var etat: Etat = .aDemander
    /// Le jeton de l'iPhone, en hexadécimal, tel qu'Apple l'a donné.
    private(set) var jeton: String?
    /// Le serveur connaît ce jeton pour le compte connecté.
    private(set) var enregistre = false

    /// Le serveur, posé par l'appli quand la session est ouverte.
    var client: ClientAPI? {
        didSet {
            enregistre = false
            Task { await enregistrer() }
        }
    }

    private static let cleJeton = "notifications.jeton"

    init() {
        jeton = UserDefaults.standard.string(forKey: Self.cleJeton)
        Task { await relire() }
    }

    /// Ce qu'iOS dit de l'accord. Accordé, l'iPhone demande son jeton à Apple :
    /// il peut changer, iOS le redonne à chaque lancement.
    func relire() async {
        let reglages = await UNUserNotificationCenter.current().notificationSettings()
        switch reglages.authorizationStatus {
        case .notDetermined: etat = .aDemander
        case .denied: etat = .refusees
        default: etat = .autorisees
        }
        if etat == .autorisees { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// La fenêtre d'iOS. À n'appeler qu'une fois l'écran d'explication lu (PRE-2).
    func demander() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        await relire()
    }

    /// iOS a rendu le jeton de l'iPhone.
    func recevoir(_ donnees: Data) {
        let lu = donnees.map { String(format: "%02x", $0) }.joined()
        if lu != jeton {
            jeton = lu
            enregistre = false
            UserDefaults.standard.set(lu, forKey: Self.cleJeton)
        }
        if !enregistre { Task { await enregistrer() } }
    }

    private struct Appareil: Encodable {
        let jeton: String
        let nom: String
        let environnement: String
    }

    /// NOT-16 : le serveur range le jeton avec le compte. Un jeton déjà connu
    /// change seulement de compte s'il le faut.
    func enregistrer() async {
        guard let client, let jeton, etat == .autorisees, !enregistre else { return }
        let appareil = Appareil(jeton: jeton, nom: UIDevice.current.name,
                                environnement: Self.environnement)
        do {
            try await client.envoyer("POST", "moi/appareils", corps: ClientAPI.corps(appareil))
            enregistre = true
        } catch {
            // Hors réseau : on réessaiera au prochain lancement.
        }
    }

    /// CNX-6 : se déconnecter retire l'iPhone de la liste des notifications.
    func oublier() async {
        guard let client, let jeton else { return }
        try? await client.envoyer("DELETE", "moi/appareils/\(jeton)", delai: 8)
        enregistre = false
    }

    /// Le service d'Apple à viser. Une appli lancée depuis Xcode est signée
    /// pour celui de développement, et son profil embarqué le dit ; une appli
    /// distribuée n'a pas de profil embarqué et vise la production.
    static let environnement: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let donnees = try? Data(contentsOf: url),
              let texte = String(data: donnees, encoding: .isoLatin1),
              let cle = texte.range(of: "<key>aps-environment</key>") else { return "production" }
        return texte[cle.upperBound...].prefix(80).contains("development") ? "developpement" : "production"
    }()
}

/// Ce qu'iOS dit à l'appli hors de SwiftUI : le jeton de notification, et les
/// notifications qui arrivent pendant qu'elle est ouverte.
@MainActor
final class DelegueApp: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let notifications = Notifications()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // ACC-14 : une demande s'accepte ou se refuse depuis sa notification.
        let accepter = UNNotificationAction(identifier: Self.accepter, title: "Accepter",
                                            options: [.authenticationRequired])
        let refuser = UNNotificationAction(identifier: Self.refuser, title: "Refuser",
                                           options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "DEMANDE", actions: [accepter, refuser],
                                   intentIdentifiers: [])])
        // SAN-11 à SAN-16 : l'historique de Santé avance iPhone branché.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: EnvoiSante.idHistorique, using: nil) { tache in
            let travail = Task { @MainActor in
                let fini = await EnvoiSante.actuel?.avancerLHistorique() ?? false
                tache.setTaskCompleted(success: fini)
            }
            tache.expirationHandler = { travail.cancel() }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        notifications.recevoir(deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Sur le simulateur ou sans réseau : rien à faire, le
        // serveur garde ses notifications en attente (NOT-2).
    }

    /// Appli ouverte : une notification du serveur s'affiche quand même en
    /// bandeau. Le minuteur de repos, lui, ne double pas l'écran de la séance.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        notification.request.trigger is UNPushNotificationTrigger ? [.banner, .list, .sound] : []
    }

    nonisolated private static let accepter = "ACCEPTER"
    nonisolated private static let refuser = "REFUSER"

    /// ACC-14 : Accepter ou Refuser, touché sur la notification d'une demande,
    /// part au serveur sans ouvrir l'appli.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive reponse: UNNotificationResponse) async {
        let geste: String
        switch reponse.actionIdentifier {
        case Self.accepter: geste = "accepter"
        case Self.refuser: geste = "refuser"
        default: return
        }
        let hal = reponse.notification.request.content.userInfo["hal"] as? [String: Any]
        guard let id = (hal?["id_demande"] as? NSNumber)?.intValue else { return }
        guard let client = await MainActor.run(body: { notifications.client }) else { return }
        try? await client.envoyer("POST", "demandes/\(id)/\(geste)")
    }
}
