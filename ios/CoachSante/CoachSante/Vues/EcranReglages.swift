import SwiftUI

struct EcranReglages: View {
    @EnvironmentObject private var synchro: Synchro
    @Environment(\.dismiss) private var fermer

    @State private var adresse = ""
    @State private var cle = ""
    @State private var joursInitiaux = 14
    @State private var resultat: String?
    @State private var occupe = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://serveur.tailnet.ts.net", text: $adresse)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Clé d'API", text: $cle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Serveur")
                } footer: {
                    Text("Sur le serveur : l'adresse Tailscale, avec Tailscale ouvert sur "
                         + "l'iPhone. Pour les essais sur le Mac : http://nom-du-mac.local:8000 "
                         + "(./outils/local.sh iphone la donne). La clé est la même que pour "
                         + "/demarrer dans le bot ; elle est gardée dans le trousseau.")
                }

                Section {
                    Stepper("Premier envoi : \(joursInitiaux) jours", value: $joursInitiaux,
                            in: 1...30)
                } footer: {
                    Text("Ensuite, chaque envoi reprend deux jours avant le dernier réussi. "
                         + "Renvoyer un jour le met à jour, sans doublon.")
                }

                Section {
                    Button("Autoriser l'accès à Santé") {
                        Task {
                            do {
                                try await synchro.lecteur.demanderAcces()
                                resultat = "Demande faite. Pour changer d'avis : Réglages, "
                                    + "Santé, Accès aux données, Coach Santé."
                                await synchro.relire()
                            } catch {
                                resultat = "Échec : \(error.localizedDescription)"
                            }
                        }
                    }
                    Button("Tester la connexion") {
                        enregistrer()
                        occupe = true
                        Task {
                            resultat = await synchro.tester()
                            occupe = false
                        }
                    }
                    .disabled(occupe)
                    if let resultat {
                        Text(resultat).font(.footnote)
                    }
                }

                Section("Envoi automatique") {
                    Text("Dans l'appli Raccourcis : Automatisation, Nouvelle, « Heure de la "
                         + "journée » (22 h 30) ou « Chargeur », puis l'action « Envoyer ma "
                         + "santé au coach ». Santé n'est lisible que si l'iPhone a été "
                         + "déverrouillé récemment.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        enregistrer()
                        fermer()
                        Task { await synchro.aLOuverture() }
                    }
                }
            }
            .onAppear {
                adresse = synchro.adresse
                cle = Trousseau.lire()
                joursInitiaux = synchro.joursInitiaux
            }
        }
    }

    private func enregistrer() {
        synchro.adresse = adresse.trimmingCharacters(in: .whitespacesAndNewlines)
        Trousseau.ecrire(cle.trimmingCharacters(in: .whitespacesAndNewlines))
        synchro.joursInitiaux = joursInitiaux
    }
}
