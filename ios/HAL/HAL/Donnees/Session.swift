import Foundation
import Observation
import Security
import UIKit

/// La clé d'API, gardée dans le trousseau de l'iPhone (CNX-1). Elle n'est
/// jamais écrite ailleurs : ni dans les réglages, ni dans les sauvegardes en clair.
enum Trousseau {
    private static let service = "fr.docxydre.hal.cle-api"

    static func lire() -> String? {
        let requete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var resultat: AnyObject?
        guard SecItemCopyMatching(requete as CFDictionary, &resultat) == errSecSuccess,
              let donnees = resultat as? Data else { return nil }
        return String(data: donnees, encoding: .utf8)
    }

    static func ecrire(_ cle: String) {
        effacer()
        let ajout: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: Data(cle.utf8),
            // Lisible après le premier déverrouillage : les tâches de fond en ont besoin.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(ajout as CFDictionary, nil)
    }

    static func effacer() {
        let requete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(requete as CFDictionary)
    }
}

/// Qui est connecté, et à quel serveur. Sans compte, l'appli tourne sur les
/// données fictives de démonstration.
@MainActor
@Observable
final class Session {
    enum Etat: Equatable {
        /// Rien de choisi : l'écran de connexion s'affiche.
        case aChoisir
        /// Les données fictives, sans serveur.
        case demonstration
        case connecte(pseudo: String)
    }

    private(set) var etat: Etat
    private(set) var adresse: URL?
    /// PRE-2 : après une connexion ou une invitation acceptée, les écrans du
    /// premier lancement passent avant l'appli, une fois par connexion.
    private(set) var accueilAFaire: Bool {
        didSet { UserDefaults.standard.set(accueilAFaire, forKey: Self.cleAccueil) }
    }

    private static let cleAdresse = "serveur.adresse"
    private static let clePseudo = "serveur.pseudo"
    private static let cleDemo = "serveur.demonstration"
    private static let cleAccueil = "serveur.accueil_a_faire"

    init() {
        // Calculés d'abord, rangés ensuite : @Observable n'accepte pas qu'on lise
        // une propriété avant que toutes soient posées.
        let reglages = UserDefaults.standard
        let lue = reglages.string(forKey: Self.cleAdresse).flatMap(URL.init(string:))
        if let pseudo = reglages.string(forKey: Self.clePseudo), lue != nil, Trousseau.lire() != nil {
            etat = .connecte(pseudo: pseudo)
        } else if reglages.bool(forKey: Self.cleDemo) {
            etat = .demonstration
        } else {
            etat = .aChoisir
        }
        adresse = lue
        accueilAFaire = reglages.bool(forKey: Self.cleAccueil)
    }

    /// Le premier lancement est fini, ou passé : l'appli s'ouvre.
    func accueilFait() {
        accueilAFaire = false
    }

    /// Réglages, Essais : revoir le premier lancement sans se reconnecter.
    func revoirAccueil() {
        if pseudo != nil { accueilAFaire = true }
    }

    /// Le client de l'API, quand un compte est connecté.
    var client: ClientAPI? {
        guard case .connecte = etat, let adresse, let cle = Trousseau.lire() else { return nil }
        return ClientAPI(adresse: adresse, cle: cle)
    }

    var pseudo: String? {
        if case .connecte(let pseudo) = etat { return pseudo }
        return nil
    }

    /// L'adresse du serveur du foyer, intégrée à l'appli à la compilation
    /// (`Serveur.local.xcconfig`) : plus rien à taper. Vide si le fichier manque,
    /// et l'écran de connexion la demande alors.
    static let serveurIntegre: String =
        (Bundle.main.object(forInfoDictionaryKey: "HALServeur") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

    /// « planif.xxx.ts.net:8443 » ou une adresse complète : on ajoute https:// s'il manque.
    static func adresse(depuis texte: String) -> URL? {
        var propre = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !propre.isEmpty else { return nil }
        if !propre.contains("://") { propre = "https://" + propre }
        if !propre.hasSuffix("/") { propre += "/" }
        return URL(string: propre)
    }

    private struct Identifiants: Encodable {
        let pseudo: String
        let motDePasse: String
        /// CNX-8 : le jeton d'Apple à relier au compte, la première fois.
        let jetonApple: String?
        /// CNX-11 : le nom de l'iPhone, pour reconnaître sa session.
        let appareil: String
    }

    private struct JetonApple: Encodable {
        let jeton: String
        let appareil: String
    }

    /// CNX-11 : le nom que le serveur donne à la session de cet iPhone.
    private static func nomAppareil() async -> String {
        await MainActor.run { UIDevice.current.name }
    }

    /// L'adresse tapée, ou celle intégrée à l'appli.
    private static func adresseVisee(_ serveur: String) throws -> URL {
        let texte = serveur.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let adresse = Self.adresse(depuis: texte.isEmpty ? serveurIntegre : texte) else {
            throw ErreurAPI(code: "adresse", message: "Donne l'adresse du serveur")
        }
        return adresse
    }

    private struct Compte: Decodable {
        let pseudo: String
        let cleApi: String
    }

    /// CNX-2 : le pseudo et le mot de passe ouvrent une session et rendent sa clé
    /// (CNX-11). Avec un jeton d'Apple, ils relient aussi l'identifiant Apple au
    /// compte (CNX-8).
    func connecter(serveur: String, pseudo: String, motDePasse: String,
                   jetonApple: String? = nil) async throws {
        let adresse = try Self.adresseVisee(serveur)
        let client = ClientAPI(adresse: adresse, cle: nil)
        let appareil = await Self.nomAppareil()
        let compte: Compte = try await client.requete(
            "POST", "connexion",
            corps: ClientAPI.corps(Identifiants(pseudo: pseudo, motDePasse: motDePasse,
                                                jetonApple: jetonApple,
                                                appareil: appareil)))
        enregistrer(adresse: adresse, compte: compte)
    }

    /// CNX-7 : « Se connecter avec Apple ». Un identifiant pas encore relié
    /// répond `apple_inconnu` : l'écran demande alors le mot de passe une fois.
    func connecterAvecApple(serveur: String, jeton: String) async throws {
        let adresse = try Self.adresseVisee(serveur)
        let client = ClientAPI(adresse: adresse, cle: nil)
        let appareil = await Self.nomAppareil()
        let compte: Compte = try await client.requete(
            "POST", "connexion/apple",
            corps: ClientAPI.corps(JetonApple(jeton: jeton, appareil: appareil)))
        enregistrer(adresse: adresse, compte: compte)
    }

    private struct Adhesion: Encodable {
        let pseudo: String
        let nom: String?
        let motDePasse: String?
        let jetonApple: String?
        let appareil: String
    }

    /// FOY-3 : un code d'invitation crée le compte et le connecte. Avec Apple,
    /// sans mot de passe (CNX-9).
    func rejoindre(serveur: String, code: String, pseudo: String, nom: String?,
                   motDePasse: String?, jetonApple: String? = nil) async throws {
        let adresse = try Self.adresseVisee(serveur)
        let propre = code.uppercased().filter { $0.isLetter || $0.isNumber }
        let client = ClientAPI(adresse: adresse, cle: nil)
        let appareil = await Self.nomAppareil()
        let compte: Compte = try await client.requete(
            "POST", "invitations/\(propre)/accepter",
            corps: ClientAPI.corps(Adhesion(pseudo: pseudo, nom: nom, motDePasse: motDePasse,
                                            jetonApple: jetonApple,
                                            appareil: appareil)))
        enregistrer(adresse: adresse, compte: compte)
    }

    func demonstration() {
        UserDefaults.standard.set(true, forKey: Self.cleDemo)
        etat = .demonstration
    }

    /// CNX-6 : le serveur révoque la clé de cet iPhone, avant qu'elle ne s'efface
    /// ici. Hors réseau, elle s'efface quand même : sa session se ferme alors
    /// depuis un autre appareil. Une clé de compte, d'avant les sessions, reste
    /// valable : le serveur répond non, sans conséquence.
    func fermerLaSession() async {
        guard let adresse, let cle = Trousseau.lire() else { return }
        try? await ClientAPI(adresse: adresse, cle: cle).envoyer("DELETE", "moi/session", delai: 8)
    }

    /// CNX-6 : se déconnecter efface la clé du trousseau. Le retrait de l'appareil
    /// de la liste des notifications et la fin de la session se font avant, par
    /// l'appelant.
    func deconnecter() {
        Trousseau.effacer()
        let reglages = UserDefaults.standard
        reglages.removeObject(forKey: Self.clePseudo)
        reglages.removeObject(forKey: Self.cleDemo)
        accueilAFaire = false
        etat = .aChoisir
    }

    private func enregistrer(adresse: URL, compte: Compte) {
        Trousseau.ecrire(compte.cleApi)
        let reglages = UserDefaults.standard
        reglages.set(adresse.absoluteString, forKey: Self.cleAdresse)
        reglages.set(compte.pseudo, forKey: Self.clePseudo)
        reglages.set(false, forKey: Self.cleDemo)
        self.adresse = adresse
        accueilAFaire = true
        etat = .connecte(pseudo: compte.pseudo)
    }
}
