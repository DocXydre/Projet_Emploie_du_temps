import SwiftUI

/// Se connecter à son serveur, rejoindre un foyer avec une invitation, ou
/// essayer l'appli sur des données fictives (CNX-2, FOY-3).
///
/// Le premier lancement complet, avec ses écrans d'accueil, arrive au lot 8.
struct EcranConnexion: View {
    @Environment(Session.self) private var session

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
    @State private var code = ""
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("HAL").texte(.grandTitre).foregroundStyle(Palette.textePrincipal)
                        Text("Le planning du foyer, la maison, le sport, et HAL.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

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
                        Text("L'administrateur du foyer te l'a donné. Il vaut 48 heures.")
                    }
                }

                Section(mode == .connexion ? "Compte" : "Ton compte") {
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
                    Text(mode == .invitation
                         ? "Au moins dix caractères pour le mot de passe."
                         : "Le mot de passe se choisit dans le bot, « /motdepasse ».")
                }

                Section {
                    Button("Essayer sans serveur") { session.demonstration() }
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("Des données fictives, pour voir l'appli. Tu pourras te connecter ensuite depuis les Réglages.")
                }
            }
            .scrollContentBackground(.hidden)
            .background { Fond() }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var complet: Bool {
        !serveur.isEmpty && !pseudo.isEmpty && !motDePasse.isEmpty
            && (mode == .connexion || code.filter { $0.isLetter || $0.isNumber }.count == 10)
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
        } catch {
            self.erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
