import SwiftUI

struct EcranReglages: View {
    @EnvironmentObject private var synchro: Synchro
    @Environment(\.dismiss) private var fermer

    @State private var adresse = ""
    @State private var cle = ""
    @State private var pseudo = ""
    @State private var motDePasse = ""
    @State private var joursInitiaux = 14
    @State private var resultat: String?
    @State private var occupe = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://planif.ton-tailnet.ts.net:8443", text: $adresse)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Pseudo", text: $pseudo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Mot de passe", text: $motDePasse)
                        .textContentType(.password)
                    Button {
                        occupe = true
                        Task {
                            await seConnecter()
                            occupe = false
                        }
                    } label: {
                        HStack {
                            Text(cle.isEmpty ? "Se connecter" : "Se reconnecter")
                            Spacer()
                            if occupe { ProgressView() }
                        }
                    }
                    .disabled(occupe || adresse.isEmpty || pseudo.isEmpty || motDePasse.isEmpty)
                    if !cle.isEmpty {
                        Label("Connecté" + (pseudo.isEmpty ? "" : " : \(pseudo)"),
                              systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    DisclosureGroup("Clé d'API, à la main") {
                        SecureField("Clé d'API", text: $cle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .font(.footnote)
                } header: {
                    Text("Serveur")
                } footer: {
                    Text("L'adresse publique du serveur, avec :8443 à la fin : elle marche "
                         + "sans Tailscale sur l'iPhone. Le mot de passe se choisit une fois "
                         + "dans le bot, avec /motdepasse. L'appli garde ensuite la clé dans "
                         + "le trousseau : tu ne te reconnectes pas à chaque fois.")
                }

                Section {
                    Stepper("Premier envoi : \(joursInitiaux) jours", value: $joursInitiaux,
                            in: 1...30)
                    Button {
                        enregistrer()
                        occupe = true
                        Task {
                            resultat = await synchro.envoyerTout()
                            occupe = false
                        }
                    } label: {
                        HStack {
                            Text("Envoyer tout l'historique")
                            Spacer()
                            if occupe, let progression = synchro.progression {
                                Text(progression).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(occupe || synchro.enCours)
                } header: {
                    Text("Historique")
                } footer: {
                    Text("Ensuite, chaque envoi reprend deux jours avant le dernier réussi. "
                         + "Renvoyer un jour le met à jour, sans doublon. « Tout l'historique » "
                         + "envoie tout ce que Santé contient, une seule fois suffit : garde "
                         + "l'appli ouverte, ça peut prendre une ou deux minutes. Les séances "
                         + "de plus de 28 jours sont gardées pour le coach sans s'ajouter à "
                         + "ton planning.")
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
                pseudo = UserDefaults.standard.string(forKey: "pseudo") ?? ""
                joursInitiaux = synchro.joursInitiaux
            }
        }
    }

    /// CNX-1 : le pseudo et le mot de passe rendent la clé d'API, gardée dans le
    /// trousseau. Le mot de passe, lui, n'est gardé nulle part.
    private func seConnecter() async {
        enregistrer()
        guard let client = ClientAPI(adresse: adresse, cle: "connexion") else {
            resultat = "Mets d'abord l'adresse du serveur, en https://."
            return
        }
        do {
            let rendu = try await client.appeler("POST", "/connexion", corps: [
                "pseudo": pseudo.trimmingCharacters(in: .whitespaces),
                "mot_de_passe": motDePasse,
            ]) as? [String: Any]
            guard let nouvelle = rendu?["cle_api"] as? String else {
                throw ErreurAPI(message: "Réponse inattendue du serveur")
            }
            cle = nouvelle
            Trousseau.ecrire(nouvelle)
            pseudo = rendu?["pseudo"] as? String ?? pseudo
            UserDefaults.standard.set(pseudo, forKey: "pseudo")
            motDePasse = ""
            resultat = "Connecté. Tu peux envoyer ta santé et lancer une séance."
        } catch {
            resultat = error.localizedDescription
        }
    }

    private func enregistrer() {
        synchro.adresse = adresse.trimmingCharacters(in: .whitespacesAndNewlines)
        Trousseau.ecrire(cle.trimmingCharacters(in: .whitespacesAndNewlines))
        synchro.joursInitiaux = joursInitiaux
    }
}
