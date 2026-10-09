import SwiftUI

@main
struct CoachSanteApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var synchro = Synchro.partage

    var body: some Scene {
        WindowGroup {
            EcranPrincipal()
                .environmentObject(synchro)
        }
        .onChange(of: phase) { _, nouvelle in
            if nouvelle == .active {
                Task { await synchro.aLOuverture() }
            }
        }
        // iOS réveille l'appli de temps en temps pour un envoi (BGAppRefresh).
        .backgroundTask(.appRefresh(Synchro.idTache)) {
            await Synchro.partage.envoyerEnFond()
        }
    }
}
