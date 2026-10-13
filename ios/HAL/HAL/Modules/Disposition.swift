import Foundation
import Observation

/// Un widget posé sur l'accueil : quel module, à quelle taille.
struct Place: Codable, Identifiable, Hashable {
    var id = UUID()
    let module: String
    var taille: TailleWidget
}

/// La disposition d'Aujourd'hui, gardée sur l'appareil (WID-4).
/// Le widget « Séance libre » n'y figure pas : il est toujours en bas à droite (WID-7).
@Observable
final class Disposition {
    private(set) var places: [Place] { didSet { enregistrer() } }

    private let cle = "disposition.aujourdhui"

    static let parDefaut: [Place] = [
        Place(module: "maintenant", taille: .moyen),
        Place(module: "aCocher", taille: .petit),
        Place(module: "sport", taille: .petit),
        Place(module: "hal", taille: .moyen),
        Place(module: "taJournee", taille: .moyen),
        Place(module: "frequenceDuJour", taille: .moyen),
        Place(module: "enRetard", taille: .petit),
    ]

    init() {
        if let donnees = UserDefaults.standard.data(forKey: cle),
           let lues = try? JSONDecoder().decode([Place].self, from: donnees) {
            places = lues.filter { Registre.module($0.module) != nil }
        } else {
            places = Self.parDefaut
        }
    }

    /// Les modules qu'on peut encore ajouter depuis la galerie.
    var disponibles: [Module] {
        Registre.tous.filter { module in !module.fixe && !places.contains { $0.module == module.id } }
    }

    func ajouter(_ module: Module, taille: TailleWidget) {
        places.append(Place(module: module.id, taille: taille))
    }

    func retirer(_ place: Place) {
        places.removeAll { $0.id == place.id }
    }

    /// Passe à la taille suivante parmi celles que le module accepte.
    func changerTaille(_ place: Place) {
        guard let rang = places.firstIndex(of: place),
              let module = Registre.module(place.module), module.tailles.count > 1 else { return }
        let actuelle = module.tailles.firstIndex(of: place.taille) ?? 0
        places[rang].taille = module.tailles[(actuelle + 1) % module.tailles.count]
    }

    /// Déplace un widget à la place d'un autre.
    func deplacer(_ id: UUID, avant cible: Place) {
        guard let depart = places.firstIndex(where: { $0.id == id }),
              let arrivee = places.firstIndex(of: cible), depart != arrivee else { return }
        let place = places.remove(at: depart)
        places.insert(place, at: arrivee)
    }

    func revenirAuParDefaut() {
        places = Self.parDefaut
    }

    /// Remet une disposition gardée, pour « Annuler ».
    func restaurer(_ anciennes: [Place]) {
        places = anciennes
    }

    private func enregistrer() {
        guard let donnees = try? JSONEncoder().encode(places) else { return }
        UserDefaults.standard.set(donnees, forKey: cle)
    }
}
