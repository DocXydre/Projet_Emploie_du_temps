import Foundation
import Security

enum Format {
    private static let instantISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static let jourISO: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// « 2026-10-09T18:30:00+02:00 » : l'API le lit sans ambiguïté de fuseau.
    static func instant(_ date: Date) -> String { instantISO.string(from: date) }

    static func jour(_ date: Date) -> String { jourISO.string(from: date) }

    static func duree(minutes: Int) -> String {
        "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }
}

struct ErreurAPI: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// L'API du serveur. Une clé par compte, dans l'en-tête `X-Cle-Api`.
struct ClientAPI {
    let base: URL
    let cle: String

    init?(adresse: String, cle: String) {
        var texte = adresse.trimmingCharacters(in: .whitespacesAndNewlines)
        while texte.hasSuffix("/") { texte.removeLast() }
        guard !cle.isEmpty, let url = URL(string: texte), url.scheme != nil, url.host != nil
        else { return nil }
        self.base = url
        self.cle = cle
    }

    @discardableResult
    func appeler(_ methode: String, _ chemin: String,
                 corps: [String: Any]? = nil) async throws -> Any? {
        guard let url = URL(string: base.absoluteString + chemin) else {
            throw ErreurAPI(message: "Adresse invalide : \(chemin)")
        }
        var requete = URLRequest(url: url, timeoutInterval: 20)
        requete.httpMethod = methode
        requete.setValue(cle, forHTTPHeaderField: "X-Cle-Api")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        if let corps {
            requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
            requete.httpBody = try JSONSerialization.data(withJSONObject: corps)
        }

        let (donnees, reponse) = try await URLSession.shared.data(for: requete)
        let json = try? JSONSerialization.jsonObject(with: donnees)
        guard let http = reponse as? HTTPURLResponse else {
            throw ErreurAPI(message: "Réponse illisible du serveur")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ErreurAPI(message: "Erreur \(http.statusCode) : \(Self.motif(json) ?? "sans détail")")
        }
        return json
    }

    /// Le motif d'un refus de l'API, quelle que soit sa forme : `{"message": …}`,
    /// `{"detail": {"message": …}}`, `{"detail": "…"}` ou la liste de pydantic.
    private static func motif(_ json: Any?) -> String? {
        guard let objet = json as? [String: Any] else { return nil }
        if let message = objet["message"] as? String { return message }
        if let detail = objet["detail"] as? [String: Any], let message = detail["message"] as? String {
            return message
        }
        if let detail = objet["detail"] as? String { return detail }
        if let liste = objet["detail"] as? [[String: Any]], let premier = liste.first {
            let champ = (premier["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".") ?? ""
            return "\(champ) : \(premier["msg"] as? String ?? "invalide")"
        }
        return nil
    }
}

/// La clé d'API vit dans le trousseau, pas dans les réglages. Lisible après le
/// premier déverrouillage, pour que l'envoi de nuit la trouve.
enum Trousseau {
    private static let service = "fr.docxydre.coachsante"
    private static let compte = "cle_api"

    static func lire() -> String {
        let requete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compte,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var resultat: AnyObject?
        guard SecItemCopyMatching(requete as CFDictionary, &resultat) == errSecSuccess,
              let donnees = resultat as? Data else { return "" }
        return String(data: donnees, encoding: .utf8) ?? ""
    }

    static func ecrire(_ cle: String) {
        let cible: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compte,
        ]
        SecItemDelete(cible as CFDictionary)
        guard !cle.isEmpty else { return }
        var ajout = cible
        ajout[kSecValueData as String] = Data(cle.utf8)
        ajout[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(ajout as CFDictionary, nil)
    }
}
