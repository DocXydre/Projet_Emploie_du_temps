import SwiftUI
import WorkoutKit

/// 5.10 : l'Apple Watch. Les séances faites avec la montre arrivent par Santé ;
/// une course prévue part sur l'app Exercice depuis sa séance (MON-1).
struct EcranMontre: View {
    @State private var etat: WorkoutScheduler.AuthorizationState?
    @State private var envoyees: Int?

    var body: some View {
        FormulaireVerre {
            Section {
                LabeledContent("Envoi à la montre", value: libelle)
                if etat != .authorized {
                    Button("Autoriser l'envoi à la montre") {
                        Task {
                            etat = await WorkoutScheduler.shared.requestAuthorization()
                            await relire()
                        }
                    }
                }
                if let envoyees {
                    LabeledContent("Séances sur la montre", value: "\(envoyees)")
                }
            } header: {
                Text("Les courses prévues")
            } footer: {
                Text("Ouvre une course ou une séance de cardio prévue par HAL, puis « Envoyer à la montre ». Elle arrive dans l'app Exercice à son heure, avec ses étapes et ses alertes. À la fin, elle revient par Santé et valide la séance toute seule.")
            }

            Section {
                Text("Toute séance faite avec la montre arrive dans HAL par Santé, même sans avoir été envoyée : une séance prévue le même jour est validée, sinon elle devient une séance libre.")
                    .foregroundStyle(Palette.textePrincipal)
            } header: {
                Text("Les séances faites")
            }
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .task { await relire() }
    }

    private var libelle: String {
        switch etat {
        case .authorized: "Autorisé"
        case .denied: "Refusé dans Réglages d'iOS"
        case .notDetermined, .none: "À autoriser"
        @unknown default: "Inconnu"
        }
    }

    private func relire() async {
        etat = await WorkoutScheduler.shared.authorizationState
        guard etat == .authorized else { return }
        envoyees = await WorkoutScheduler.shared.scheduledWorkouts.count
    }
}
