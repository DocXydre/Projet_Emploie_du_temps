import SwiftUI

@main
struct HALApp: App {
    @State private var apparence = Apparence()
    @State private var foyer: Foyer
    @State private var file: FileAttente
    @State private var conversation = ConversationHAL()
    @State private var disposition = Disposition()

    init() {
        let foyer = Foyer()
        _foyer = State(initialValue: foyer)
        _file = State(initialValue: FileAttente(expediteur: ExpediteurFictif(foyer: foyer)))
    }

    var body: some Scene {
        WindowGroup {
            Racine()
                .environment(apparence)
                .environment(foyer)
                .environment(file)
                .environment(conversation)
                .environment(disposition)
                .environment(\.theme, apparence.theme)
                .tint(apparence.theme.principal)
                .preferredColorScheme(.dark)
        }
    }
}
