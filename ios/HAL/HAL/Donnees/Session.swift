import Foundation
import Observation
import Security

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

    private static let cleAdresse = "serveur.adresse"
    private static let clePseudo = "serveur.pseudo"
    private static let cleDemo = "serveur.demonstration"

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
    }

    private struct Compte: Decodable {
        let pseudo: String
        let cleApi: String
    }

    /// CNX-2 : le pseudo et le mot de passe rendent la clé d'API.
    func connecter(serveur: String, pseudo: String, motDePasse: String) async throws {
        guard let adresse = Self.adresse(depuis: serveur) else {
            throw ErreurAPI(code: "adresse", message: "Donne l'adresse du serveur")
        }
        let client = ClientAPI(adresse: adresse, cle: nil)
        let compte: Compte = try await client.requete(
            "POST", "connexion", corps: ClientAPI.corps(Identifiants(pseudo: pseudo, motDePasse: motDePasse)))
        enregistrer(adresse: adresse, compte: compte)
    }

    private struct Adhesion: Encodable {
        let pseudo: String
        let nom: String?
        let motDePasse: String
    }

    /// FOY-3 : un code d'invitation crée le compte et le connecte.
    func rejoindre(serveur: String, code: String, pseudo: String, nom: String?,
                   motDePasse: String) async throws {
        guard let adresse = Self.adresse(depuis: serveur) else {
            throw ErreurAPI(code: "adresse", message: "Donne l'adresse du serveur")
        }
        let propre = code.uppercased().filter { $0.isLetter || $0.isNumber }
        let client = ClientAPI(adresse: adresse, cle: nil)
        let compte: Compte = try await client.requete(
            "POST", "invitations/\(propre)/accepter",
            corps: ClientAPI.corps(Adhesion(pseudo: pseudo, nom: nom, motDePasse: motDePasse)))
        enregistrer(adresse: adresse, compte: compte)
    }

    func demonstration() {
        UserDefaults.standard.set(true, forKey: Self.cleDemo)
        etat = .demonstration
    }

    /// CNX-6 : se déconnecter efface la clé du trousseau. Le retrait de l'appareil
    /// de la liste des notifications se fait avant, par l'appelant.
    func deconnecter() {
        Trousseau.effacer()
        let reglages = UserDefaults.standard
        reglages.removeObject(forKey: Self.clePseudo)
        reglages.removeObject(forKey: Self.cleDemo)
        etat = .aChoisir
    }

    private func enregistrer(adresse: URL, compte: Compte) {
        Trousseau.ecrire(compte.cleApi)
        let reglages = UserDefaults.standard
        reglages.set(adresse.absoluteString, forKey: Self.cleAdresse)
        reglages.set(compte.pseudo, forKey: Self.clePseudo)
        reglages.set(false, forKey: Self.cleDemo)
        self.adresse = adresse
        etat = .connecte(pseudo: compte.pseudo)
    }
}
