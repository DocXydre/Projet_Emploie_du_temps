import SwiftUI

@main
struct HALApp: App {
    @State private var apparence = Apparence()
    @State private var session = Session()
    @State private var foyer: Foyer
    @State private var file: FileAttente
    @State private var conversation = ConversationHAL()
    @State private var disposition = Disposition()
    @Environment(\.scenePhase) private var phase

    init() {
        let foyer = Foyer()
        _foyer = State(initialValue: foyer)
        _file = State(initialValue: FileAttente(expediteur: ExpediteurFictif(foyer: foyer)))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.etat == .aChoisir {
                    EcranConnexion()
                } else {
                    Racine()
                }
            }
            .environment(apparence)
            .environment(session)
            .environment(foyer)
            .environment(file)
            .environment(conversation)
            .environment(disposition)
            .environment(\.theme, apparence.theme)
            .tint(apparence.theme.principal)
            .preferredColorScheme(.dark)
            .task(id: session.etat) {
                brancher()
                await rafraichirEnContinu()
            }
            .onChange(of: phase) { _, nouvelle in
                if nouvelle == .active { Task { await foyer.charger() } }
            }
        }
    }

    /// La session choisit la source des données et l'expéditeur de la file.
    private func brancher() {
        if let client = session.client {
            foyer.brancher(client)
            file.expediteur = ExpediteurAPI(client: client)
            let foyer = foyer
            file.apresEnvoi = { await foyer.charger() }
            Task { await file.vider() }
        } else {
            foyer.debrancher()
            file.expediteur = ExpediteurFictif(foyer: foyer)
            file.apresEnvoi = nil
        }
    }

    /// Toutes les deux minutes, tant que l'appli est ouverte : l'autre a pu cocher
    /// une tâche, un cours a pu tomber.
    private func rafraichirEnContinu() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            if phase == .active { await foyer.charger() }
        }
    }
}
