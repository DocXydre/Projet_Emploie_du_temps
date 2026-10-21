import Foundation

/// Le registre unique des modules (WID-1). La galerie le lit : un module inscrit
/// ici y apparaît tout seul.
enum Registre {
    static let tous: [Module] = [
        .maintenant,
        .taJournee,
        .aCocher,
        .sport,
        .enRetard,
        .hal,
        .forme,
        .objectif,
        .chat,
        .equilibre,
        .frequenceDuJour,
        .weekend,
        .train,
        .semaine,
        .montre,
        .derniereCourse,
        .seanceEnCours,
        .linge,
        .bientot,
        .seanceLibre,
    ]

    /// Les modules qui passent en tête quand leur raison existe (WID-6).
    /// Ils ne s'ajoutent pas à la main.
    static let prioritaires: [Module] = [.conflit, .ajustement, .mesureDemandee, .effortADonner, .lancerSeance]

    static func module(_ id: String) -> Module? {
        (tous + prioritaires).first { $0.id == id }
    }
}
