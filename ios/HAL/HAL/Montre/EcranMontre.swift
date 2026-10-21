import SwiftUI
import WorkoutKit

/// 5.10 : l'Apple Watch, ou Strava sans elle. L'interrupteur dit au serveur et à
/// HAL si le compte a une montre (MON-7). Avec elle, une course prévue part sur
/// l'app Exercice depuis sa séance (MON-1) ; sans elle, Strava écrit ses
/// activités dans Santé, et l'appli les lit de là (MON-10).
struct EcranMontre: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.openURL) private var ouvrir
    @State private var etat: WorkoutScheduler.AuthorizationState?
    @State private var envoyees: Int?

    var body: some View {
        FormulaireVerre {
            Section {
                InterrupteurMontre()
            } footer: {
                Text(foyer.aUneMontre
                     ? "HAL lit la fréquence cardiaque, la VFC et les phases de sommeil, et les courses partent sur la montre."
                     : "Sans montre, l'appli retire ce qui ne vit que par elle. La musculation ne change pas ; la course se court avec Strava ou une autre appli, et ton effort se note de 1 à 10 ; le sommeil est celui que l'iPhone estime.")
            }

            if foyer.aUneMontre {
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

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    etape(1, "Dans Strava : Vous, puis l'engrenage des réglages.")
                    etape(2, "Applications, services et appareils, puis Santé (ou Apple Santé).")
                    etape(3, "Connecter, et autoriser l'écriture des entraînements.")
                }
                .padding(.vertical, 4)
                Button("Ouvrir Strava") {
                    if let lien = URL(string: "strava://") { ouvrir(lien) }
                }
            } header: {
                Text("Strava")
            } footer: {
                Text("Strava écrit alors chaque activité dans Santé, et HAL la lit de là avec le reste : une course compte la séance prévue du même jour comme faite. Reçue de Strava et de la montre, elle ne compte qu'une fois. Sans rien pour l'enregistrer, une course se déclare à la main, dans le « + ».")
            }
        }
        .navigationTitle("Apple Watch et Strava")
        .navigationBarTitleDisplayMode(.inline)
        .task { await relire() }
    }

    private func etape(_ rang: Int, _ texte: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(rang)").texte(.corpsFort).foregroundStyle(Categorie.sport.couleur)
            Text(texte).foregroundStyle(Palette.textePrincipal)
                .fixedSize(horizontal: false, vertical: true)
        }
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

/// MON-7 : « J'ai une Apple Watch », réglé à la main. Rien ne le devine.
struct InterrupteurMontre: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        Toggle(isOn: Binding(get: { foyer.aUneMontre }, set: { valeur in
            Task {
                do {
                    try await foyer.reglerLaMontre(valeur)
                } catch {
                    annoncer((error as? ErreurAPI)?.message ?? "Réglage impossible pour l'instant")
                }
            }
        })) {
            HStack(spacing: 12) {
                Pastille(icone: "applewatch", couleur: Categorie.sport.couleur)
                Text("J'ai une Apple Watch").foregroundStyle(Palette.textePrincipal)
            }
        }
        .tint(Categorie.sport.couleur)
    }
}
