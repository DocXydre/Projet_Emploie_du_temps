import SwiftUI

@main
struct HALApp: App {
    @State private var apparence = Apparence()
    @State private var session = Session()
    @State private var foyer: Foyer
    @State private var file: FileAttente
    @State private var conversation = ConversationHAL()
    @State private var disposition = Disposition()
    @State private var seance = SeanceEnCours()
    @State private var sante = EnvoiSante()
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
            .environment(seance)
            .environment(sante)
            .environment(\.theme, apparence.theme)
            .environment(\.verre, apparence.verre)
            .tint(apparence.theme.principal)
            .preferredColorScheme(.dark)
            .task(id: session.etat) {
                brancher()
                await rafraichirEnContinu()
            }
            .onChange(of: phase) { _, nouvelle in
                guard nouvelle == .active else { return }
                Task {
                    await foyer.charger()
                    // ORB-8 : un message resté sans réponse repart à l'ouverture.
                    await conversation.charger()
                    await lireSante()
                }
            }
        }
        // SAN-10 : iOS réveille l'appli de temps en temps pour envoyer Santé.
        .backgroundTask(.appRefresh(EnvoiSante.idTache)) {
            await sante.envoyerEnFond()
        }
    }

    /// Santé : l'envoi au serveur, et la fréquence du jour pour le widget.
    private func lireSante() async {
        await sante.aLOuverture()
        foyer.poserLaFrequence(sante.frequenceDuJour)
    }

    /// La session choisit la source des données et l'expéditeur de la file.
    private func brancher() {
        if let client = session.client {
            foyer.brancher(client)
            sante.client = client
            conversation.client = client
            let foyerBranche = foyer
            conversation.apresAction = { await foyerBranche.charger() }
            Task { await lireSante() }
            Task { await conversation.charger() }
            file.expediteur = ExpediteurAPI(client: client)
            let foyer = foyer
            file.apresEnvoi = { await foyer.charger() }
            Task { await file.vider() }
        } else {
            foyer.debrancher()
            sante.client = nil
            conversation.client = nil
            conversation.apresAction = nil
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
