import AuthenticationServices
import SwiftUI

/// Se connecter à son serveur [5.14], rejoindre un foyer avec une invitation
/// [5.18], ou essayer l'appli sur des données fictives (PRE-1, CNX-2, FOY-3).
///
/// Avec Apple, ou avec le pseudo et le mot de passe (CNX-7). L'adresse du
/// serveur est intégrée à l'appli : on ne la tape que pour en viser un autre.
///
/// Un lien d'invitation ouvre cet écran avec le code et l'adresse du serveur
/// déjà remplis : il ne reste qu'à choisir son pseudo, puis Apple ou un mot de
/// passe. Le premier lancement suit (PRE-2).
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
    /// Taper l'adresse d'un autre serveur que celui intégré à l'appli.
    @State private var autreServeur = Session.serveurIntegre.isEmpty
    /// CNX-8 : Apple a dit qui on est, mais l'identifiant n'est relié à aucun
    /// compte. Le pseudo et le mot de passe le relient, une fois.
    @State private var jetonARelier: String?
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
                    if autreServeur {
                        Section("Serveur") {
                            TextField("adresse.ts.net:8443", text: $serveur)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }

                    if mode == .invitation {
                        Section {
                            TextField("ABCDE-FGHJK", text: $code)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                        } header: {
                            Text("Code d'invitation")
                        }
                    }
                }

                if mode == .connexion && jetonARelier == nil {
                    Section {
                        boutonApple(.signIn)
                    } footer: {
                        Text("Ou avec ton pseudo et ton mot de passe :")
                    }
                } else if jetonARelier != nil {
                    Section {
                        Label("Première fois avec Apple : connecte-toi avec ton pseudo et ton mot de passe. Ensuite, Apple suffira.",
                              systemImage: "apple.logo")
                            .foregroundStyle(Palette.textePrincipal)
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

                // CNX-9 : rejoindre avec Apple, sans mot de passe. Le pseudo d'abord.
                if mode == .invitation {
                    Section {
                        boutonApple(.signUp)
                            .disabled(!inviteSansMotDePasse)
                            .opacity(inviteSansMotDePasse ? 1 : 0.5)
                    } footer: {
                        Text("Avec Apple, pas de mot de passe à choisir : le code et le pseudo suffisent.")
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
                        Text("Oublié : demande à l'administrateur du serveur.")
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
                        if !Session.serveurIntegre.isEmpty {
                            Button(autreServeur ? "Serveur du foyer" : "Autre serveur") {
                                autreServeur.toggle()
                            }
                            .frame(maxWidth: .infinity)
                        }
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
            if let adresse = invitation.serveur, !adresse.isEmpty {
                serveur = adresse
                depuisUnLien = true
            } else {
                depuisUnLien = !serveurVise.isEmpty
            }
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
            autreServeur = true
            serveur = morceaux[0]
            pseudo = morceaux[1]
            motDePasse = morceaux[2]
            await valider()
        }
        #endif
    }

    /// L'adresse que vise l'écran : celle d'un lien ou tapée, sinon celle
    /// intégrée à l'appli.
    private var serveurVise: String {
        depuisUnLien || autreServeur ? serveur : Session.serveurIntegre
    }

    private var complet: Bool {
        guard !serveurVise.isEmpty, !pseudo.isEmpty, !motDePasse.isEmpty else { return false }
        if mode == .connexion { return true }
        return code.filter { $0.isLetter || $0.isNumber }.count == 10
            && motDePasse.count >= 10 && motDePasse == confirmation
    }

    /// Rejoindre avec Apple : le code et un pseudo valable, sans mot de passe.
    private var inviteSansMotDePasse: Bool {
        !serveurVise.isEmpty && code.filter { $0.isLetter || $0.isNumber }.count == 10
            && pseudo.count >= 3 && !enCours
    }

    /// « Se connecter avec Apple », ou « S'inscrire avec Apple » pour une invitation.
    private func boutonApple(_ libelle: SignInWithAppleButton.Label) -> some View {
        SignInWithAppleButton(libelle) { demande in
            // Le prénom ne sert qu'à qui arrive : Apple ne le donne qu'une fois.
            demande.requestedScopes = mode == .invitation ? [.fullName] : []
        } onCompletion: { resultat in
            Task { await apple(resultat) }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 50)
        .clipShape(.capsule)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .disabled(enCours)
    }

    private func apple(_ resultat: Result<ASAuthorization, Error>) async {
        switch resultat {
        case .failure(let echec):
            // Fermer la feuille d'Apple n'est pas une erreur.
            if (echec as? ASAuthorizationError)?.code != .canceled {
                erreur = "Apple n'a pas pu confirmer qui tu es. Réessaie."
            }
        case .success(let autorisation):
            guard let identite = autorisation.credential as? ASAuthorizationAppleIDCredential,
                  let donnees = identite.identityToken,
                  let jeton = String(data: donnees, encoding: .utf8) else {
                erreur = "Apple n'a pas pu confirmer qui tu es. Réessaie."
                return
            }
            if mode == .invitation, nom.isEmpty, let prenom = identite.fullName?.givenName {
                nom = prenom
            }
            await envoyer {
                switch mode {
                case .connexion:
                    try await session.connecterAvecApple(serveur: serveurVise, jeton: jeton)
                case .invitation:
                    try await session.rejoindre(serveur: serveurVise, code: code, pseudo: pseudo,
                                                nom: nom.isEmpty ? nil : nom, motDePasse: nil,
                                                jetonApple: jeton)
                }
            } inconnu: {
                jetonARelier = jeton
            }
        }
    }

    private func valider() async {
        await envoyer {
            switch mode {
            case .connexion:
                try await session.connecter(serveur: serveurVise, pseudo: pseudo,
                                            motDePasse: motDePasse, jetonApple: jetonARelier)
            case .invitation:
                try await session.rejoindre(serveur: serveurVise, code: code, pseudo: pseudo,
                                            nom: nom.isEmpty ? nil : nom, motDePasse: motDePasse)
            }
            motDePasse = ""
            confirmation = ""
            jetonARelier = nil
        }
    }

    /// Envoie, et traduit ce qui revient en une ligne lisible. `inconnu` :
    /// l'identifiant Apple n'est relié à aucun compte (CNX-8).
    private func envoyer(_ action: () async throws -> Void,
                         inconnu: () -> Void = {}) async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        do {
            try await action()
        } catch let refus as ErreurAPI where refus.code == "apple_inconnu" {
            inconnu()
        } catch let refus as ErreurAPI where refus.statut == 0 && refus.code == "injoignable" {
            // Pas une réponse du serveur : l'adresse, ou le réseau.
            erreur = autreServeur ? "Serveur injoignable : vérifie l'adresse et ta connexion."
                                  : "Serveur injoignable : vérifie ta connexion."
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
