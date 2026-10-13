import Foundation
import Network
import Observation

/// Un envoi au serveur, gardé tant qu'il n'est pas parti. Son identifiant est la
/// clé créée par l'appareil : le renvoyer ne crée rien de plus côté serveur (APP-3, SAI-9).
struct Envoi: Codable, Identifiable, Hashable {
    let id: UUID
    let methode: String
    let chemin: String
    let corps: Data?
    /// L'heure où l'utilisateur l'a fait, pas celle où il arrive (SAI-11).
    let fait: Date
}

enum ResultatEnvoi {
    case envoye
    /// Le serveur a répondu non : l'envoi est retiré et son motif affiché (APP-5).
    case refuse(String)
    /// Pas de réseau ou serveur coupé : l'envoi reste dans la file.
    case injoignable
}

/// Ce qui transmet un envoi. Un faux pour l'instant, le client de l'API ensuite.
protocol Expediteur {
    func envoyer(_ envoi: Envoi) async -> ResultatEnvoi
}

/// La file des envois en attente, gardée sur le téléphone et vidée dans l'ordre
/// dès que le réseau revient.
@MainActor
@Observable
final class FileAttente {
    private(set) var enAttente: [Envoi] = []
    private(set) var dernierRefus: String?
    private(set) var reseauDisponible = true
    var expediteur: Expediteur

    private let surveillance = NWPathMonitor()
    private var envoiEnCours = false

    init(expediteur: Expediteur) {
        self.expediteur = expediteur
        enAttente = Self.lire()
        surveillance.pathUpdateHandler = { [weak self] chemin in
            let disponible = chemin.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.reseauDisponible = disponible
                if disponible { await self.vider() }
            }
        }
        surveillance.start(queue: DispatchQueue(label: "fr.docxydre.hal.reseau"))
    }

    func ajouter(methode: String, chemin: String, corps: Data? = nil) {
        enAttente.append(Envoi(id: UUID(), methode: methode, chemin: chemin, corps: corps, fait: .now))
        enregistrer()
        Task { await vider() }
    }

    /// Envoie tout ce qui attend, du plus ancien au plus récent. S'arrête au premier
    /// envoi injoignable : la suite attend avec lui, pour garder l'ordre.
    func vider() async {
        guard !envoiEnCours else { return }
        envoiEnCours = true
        defer { envoiEnCours = false }

        while let premier = enAttente.first {
            switch await expediteur.envoyer(premier) {
            case .envoye:
                enAttente.removeFirst()
            case .refuse(let motif):
                enAttente.removeFirst()
                dernierRefus = motif
            case .injoignable:
                enregistrer()
                return
            }
            enregistrer()
        }
    }

    func oublierRefus() { dernierRefus = nil }

    private func enregistrer() {
        guard let donnees = try? JSONEncoder().encode(enAttente) else { return }
        try? donnees.write(to: Self.fichier, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static var fichier: URL {
        let dossier = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        return dossier.appendingPathComponent("file-attente.json")
    }

    private static func lire() -> [Envoi] {
        guard let donnees = try? Data(contentsOf: fichier) else { return [] }
        return (try? JSONDecoder().decode([Envoi].self, from: donnees)) ?? []
    }
}

/// L'expéditeur des données fictives : il échoue quand l'essai « hors réseau » est actif.
struct ExpediteurFictif: Expediteur {
    let foyer: Foyer

    func envoyer(_ envoi: Envoi) async -> ResultatEnvoi {
        try? await Task.sleep(for: .milliseconds(300))
        let coupe = await MainActor.run { foyer.essais.horsReseau }
        return coupe ? .injoignable : .envoye
    }
}
