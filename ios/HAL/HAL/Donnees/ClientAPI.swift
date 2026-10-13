import Foundation

/// Ce que le serveur répond quand il dit non : toujours `{"code", "message"}`.
struct ErreurAPI: Error, LocalizedError, Decodable {
    var code: String
    var message: String
    /// Le statut HTTP. Zéro : la requête n'est pas arrivée au serveur.
    var statut: Int = 0

    var errorDescription: String? { message }

    /// Pas de réseau, serveur coupé, ou réponse illisible : on réessaiera.
    var injoignable: Bool { statut == 0 || statut >= 500 }

    static func reseau(_ erreur: Error) -> ErreurAPI {
        ErreurAPI(code: "injoignable", message: "Serveur injoignable", statut: 0)
    }

    private enum CodingKeys: String, CodingKey { case code, message }
}

/// Le client de l'API du serveur. Il porte la clé d'API dans l'en-tête X-Cle-Api
/// (CNX-1), décode les réponses en `snake_case` et les dates ISO 8601.
struct ClientAPI: Sendable {
    let adresse: URL
    let cle: String?

    static let decodeur: JSONDecoder = {
        let decodeur = JSONDecoder()
        decodeur.keyDecodingStrategy = .convertFromSnakeCase
        decodeur.dateDecodingStrategy = .custom { decodeur in
            let texte = try decodeur.singleValueContainer().decode(String.self)
            if let date = Dates.lire(texte) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decodeur.codingPath,
                                                    debugDescription: "Date illisible : \(texte)"))
        }
        return decodeur
    }()

    static let encodeur: JSONEncoder = {
        let encodeur = JSONEncoder()
        encodeur.keyEncodingStrategy = .convertToSnakeCase
        encodeur.dateEncodingStrategy = .iso8601
        return encodeur
    }()

    /// Une requête, et sa réponse décodée.
    func requete<Reponse: Decodable>(_ methode: String, _ chemin: String,
                                     corps: Data? = nil,
                                     cleAppareil: UUID? = nil,
                                     en type: Reponse.Type = Reponse.self) async throws -> Reponse {
        let donnees = try await brut(methode, chemin, corps: corps, cleAppareil: cleAppareil)
        do {
            return try Self.decodeur.decode(Reponse.self, from: donnees)
        } catch {
            throw ErreurAPI(code: "reponse_illisible", message: "Réponse du serveur illisible", statut: 0)
        }
    }

    /// Une requête dont on n'attend que le succès.
    func envoyer(_ methode: String, _ chemin: String, corps: Data? = nil,
                 cleAppareil: UUID? = nil) async throws {
        _ = try await brut(methode, chemin, corps: corps, cleAppareil: cleAppareil)
    }

    /// Encode un corps de requête.
    static func corps<Valeur: Encodable>(_ valeur: Valeur) -> Data? {
        try? encodeur.encode(valeur)
    }

    private func brut(_ methode: String, _ chemin: String, corps: Data?,
                      cleAppareil: UUID?) async throws -> Data {
        guard let url = URL(string: chemin, relativeTo: adresse) else {
            throw ErreurAPI(code: "adresse", message: "Adresse invalide", statut: 0)
        }
        var demande = URLRequest(url: url, timeoutInterval: 20)
        demande.httpMethod = methode
        demande.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cle { demande.setValue(cle, forHTTPHeaderField: "X-Cle-Api") }
        // APP-3 : la clé de l'envoi, créée par l'appareil. Le serveur pourra s'en
        // servir pour ignorer un envoi rejoué.
        if let cleAppareil { demande.setValue(cleAppareil.uuidString, forHTTPHeaderField: "X-Cle-Appareil") }
        if let corps {
            demande.httpBody = corps
            demande.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let donnees: Data
        let reponse: URLResponse
        do {
            (donnees, reponse) = try await URLSession.shared.data(for: demande)
        } catch {
            throw ErreurAPI.reseau(error)
        }
        let statut = (reponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statut) else {
            var erreur = (try? Self.decodeur.decode(ErreurAPI.self, from: donnees))
                ?? ErreurAPI(code: "erreur", message: "Le serveur a répondu \(statut)")
            erreur.statut = statut
            throw erreur
        }
        return donnees
    }
}

/// Les dates de l'API : ISO 8601, avec ou sans fractions de seconde, et les
/// jours seuls (« 2026-10-13 »), lus à l'heure de Paris.
enum Dates {
    private static let complete: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    private static let simple = ISO8601DateFormatter()

    private static let jour: DateFormatter = {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "Europe/Paris")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    static func lire(_ texte: String) -> Date? {
        complete.date(from: texte) ?? simple.date(from: texte) ?? jour.date(from: texte)
    }

    /// « aujourd'hui », « demain », « dans 4 jours » : ce que dit le widget du chat.
    static func relatif(_ date: Date?, maintenant: Date = .now) -> String {
        guard let date else { return "rien de prévu" }
        let calendrier = Calendar.current
        let jours = calendrier.dateComponents([.day], from: calendrier.startOfDay(for: maintenant),
                                              to: calendrier.startOfDay(for: date)).day ?? 0
        switch jours {
        case ..<0: return "en retard"
        case 0: return "aujourd'hui"
        case 1: return "demain"
        default: return "dans \(jours) jours"
        }
    }
}
