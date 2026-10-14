import SwiftUI

/// Se connecter à son serveur [5.14], rejoindre un foyer avec une invitation
/// [5.18], ou essayer l'appli sur des données fictives (PRE-1, CNX-2, FOY-3).
///
/// Un lien d'invitation ouvre cet écran avec le code et l'adresse du serveur
/// déjà remplis : il ne reste qu'à choisir son pseudo et son mot de passe. Le
/// premier lancement suit (PRE-2).
struct EcranConnexion: View {
    @Environment(Session.self) private var session
    @Environment(Aiguillage.self) private var aiguillage

    private enum Mode: String, CaseIterable, Identifiable {
        case connexion = "J'ai un compte"
        case invitation = "J'ai une invitation"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .connexion
    @AppStorage("serveur.saisi") private var serveur = ""
    @State private var pseudo = ""
    @State private var nom = ""
    @State private var motDePasse = ""
    @State private var confirmation = ""
    @State private var code = ""
    /// Le code et le serveur viennent d'un lien : ils s'affichent sans se retaper.
    @State private var depuisUnLien = false
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        NavigationStack {
            FormulaireVerre {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(depuisUnLien ? "Rejoindre le foyer" : "HAL")
                            .texte(.grandTitre).foregroundStyle(Palette.textePrincipal)
                        Text(depuisUnLien
                             ? "On t'invite : choisis ton pseudo et ton mot de passe, et tu arrives dans le foyer."
                             : "Le planning du foyer, la maison, le sport, et HAL.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    .listRowBackground(Color.clear)
                }

                if !depuisUnLien {
                    Section {
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                    }
                }

                if depuisUnLien {
                    Section {
                        LabeledContent("Code", value: code)
                        LabeledContent("Serveur", value: Session.adresse(depuis: serveur)?.host() ?? serveur)
                    } header: {
                        Text("L'invitation")
                    } footer: {
                        Text("Valable 48 heures, une seule fois.")
                    }
                } else {
                    Section("Serveur") {
                        TextField("adresse.ts.net:8443", text: $serveur)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if mode == .invitation {
                        Section {
                            TextField("ABCDE-FGHJK", text: $code)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                        } header: {
                            Text("Code d'invitation")
                        } footer: {
                            Text("L'administrateur du foyer te l'a donné. Il vaut 48 heures, une seule fois.")
                        }
                    }
                }

                Section {
                    TextField("Pseudo", text: $pseudo)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if mode == .invitation {
                        TextField("Prénom (facultatif)", text: $nom)
                            .textContentType(.givenName)
                    }
                    SecureField("Mot de passe", text: $motDePasse)
                        .textContentType(mode == .connexion ? .password : .newPassword)
                    if mode == .invitation {
                        SecureField("Encore une fois", text: $confirmation)
                            .textContentType(.newPassword)
                    }
                } header: {
                    Text(mode == .connexion ? "Compte" : "Ton compte")
                } footer: {
                    if mode == .invitation {
                        Text("Le pseudo : de 3 à 30 caractères, lettres sans accent, chiffres, point ou tiret. Le mot de passe : dix caractères au moins.")
                    }
                }

                if let erreur {
                    Section {
                        Label(erreur, systemImage: "exclamationmark.circle")
                            .foregroundStyle(Categorie.alerte.couleur)
                    }
                }

                Section {
                    Button {
                        Task { await valider() }
                    } label: {
                        HStack {
                            Spacer()
                            if enCours { ProgressView() } else {
                                Text(mode == .connexion ? "Se connecter" : "Rejoindre le foyer").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(enCours || !complet)
                } footer: {
                    if mode == .connexion {
                        Text("Ton mot de passe se choisit en rejoignant le foyer, puis se change dans Réglages. Oublié : demande à l'administrateur du serveur.")
                    } else if !motDePasse.isEmpty && !confirmation.isEmpty && motDePasse != confirmation {
                        Text("Les deux mots de passe ne sont pas les mêmes.")
                    }
                }

                if depuisUnLien {
                    Section {
                        Button("J'ai déjà un compte") {
                            depuisUnLien = false
                            mode = .connexion
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Section {
                        Button("Essayer sans serveur") { session.demonstration() }
                            .frame(maxWidth: .infinity)
                    } footer: {
                        Text("Des données fictives, pour voir l'appli. Tu pourras te connecter ensuite depuis les Réglages.")
                    }
                }
            }
            .background { Fond() }
            .scrollDismissesKeyboard(.interactively)
        }
        // 5.18 : un lien d'invitation remplit le code et le serveur.
        .onChange(of: aiguillage.invitation, initial: true) { _, invitation in
            guard let invitation else { return }
            mode = .invitation
            code = invitation.code.uppercased()
            if let adresse = invitation.serveur, !adresse.isEmpty { serveur = adresse }
            depuisUnLien = !serveur.isEmpty
            erreur = nil
            aiguillage.invitation = nil
        }
        #if DEBUG && targetEnvironment(simulator)
        // Le simulateur ne colle rien dans un champ de mot de passe. Pour la
        // fausse base (outils/fausse_base.sh), le lancement peut donner
        // HAL_CONNEXION="http://localhost:8000 thomas maquette-thomas" :
        // l'écran se remplit et se valide seul. Absent de l'appli de l'iPhone.
        .task {
            let morceaux = (ProcessInfo.processInfo.environment["HAL_CONNEXION"] ?? "")
                .split(separator: " ").map(String.init)
            guard morceaux.count == 3 else { return }
            mode = .connexion
            serveur = morceaux[0]
            pseudo = morceaux[1]
            motDePasse = morceaux[2]
            await valider()
        }
        #endif
    }

    private var complet: Bool {
        guard !serveur.isEmpty, !pseudo.isEmpty, !motDePasse.isEmpty else { return false }
        if mode == .connexion { return true }
        return code.filter { $0.isLetter || $0.isNumber }.count == 10
            && motDePasse.count >= 10 && motDePasse == confirmation
    }

    private func valider() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        do {
            switch mode {
            case .connexion:
                try await session.connecter(serveur: serveur, pseudo: pseudo, motDePasse: motDePasse)
            case .invitation:
                try await session.rejoindre(serveur: serveur, code: code, pseudo: pseudo,
                                            nom: nom.isEmpty ? nil : nom, motDePasse: motDePasse)
            }
            motDePasse = ""
            confirmation = ""
        } catch let refus as ErreurAPI where refus.statut == 0 && refus.code == "injoignable" {
            // Pas une réponse du serveur : l'adresse, ou le réseau.
            erreur = "Serveur injoignable : vérifie l'adresse et ta connexion."
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
