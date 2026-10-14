import SwiftUI

@main
struct HALApp: App {
    @UIApplicationDelegateAdaptor(DelegueApp.self) private var delegue
    @State private var apparence = Apparence()
    @State private var session = Session()
    @State private var foyer: Foyer
    @State private var file: FileAttente
    @State private var conversation = ConversationHAL()
    @State private var disposition = Disposition()
    @State private var seance = SeanceEnCours()
    @State private var sante = EnvoiSante()
    @State private var aiguillage = Aiguillage()
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
                } else if session.accueilAFaire, session.pseudo != nil {
                    // PRE-2 : Santé, les notifications, les calendriers, HAL.
                    EcranPremierLancement()
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
            .environment(aiguillage)
            .environment(delegue.notifications)
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
                    // Un accord donné ou retiré dans les réglages d'iOS.
                    await delegue.notifications.relire()
                }
            }
            // 5.18 : la page d'un lien d'invitation ouvre l'appli sur « Rejoindre ».
            .onOpenURL { url in ouvrir(url) }
        }
        // SAN-10 : iOS réveille l'appli de temps en temps pour envoyer Santé.
        .backgroundTask(.appRefresh(EnvoiSante.idTache)) {
            await sante.envoyerEnFond()
        }
    }

    /// Une invitation se lit sans compte : connecté, l'appli dit pourquoi elle
    /// ne s'en sert pas ; en démonstration, elle revient à la connexion.
    private func ouvrir(_ url: URL) {
        guard aiguillage.ouvrir(url) else { return }
        switch session.etat {
        case .connecte:
            aiguillage.invitation = nil
            aiguillage.invitationRefusee = true
        case .demonstration:
            session.deconnecter()
        case .aChoisir:
            break
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
            delegue.notifications.client = client
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
            delegue.notifications.client = nil
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
