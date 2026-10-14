import AppIntents

/// « Envoyer ma santé » dans l'appli Raccourcis : à brancher sur une
/// automatisation (le soir à 22 h 30, ou quand l'iPhone se met en charge).
/// L'envoi se fait sans ouvrir l'appli, si l'iPhone est déverrouillé.
struct EnvoyerSante: AppIntent {
    static let title: LocalizedStringResource = "Envoyer ma santé au coach"
    static let description = IntentDescription(
        "Lit l'application Santé et envoie les jours et les séances au serveur du coach.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let bilan = await Synchro.partage.synchroniser(raison: "raccourci")
        return .result(dialog: "\(bilan)")
    }
}

struct RaccourcisCoachSante: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: EnvoyerSante(),
                    phrases: ["Envoyer ma santé avec \(.applicationName)"],
                    shortTitle: "Envoyer ma santé",
                    systemImageName: "heart.text.square")
    }
}
