import SwiftUI

// Réglages, Lieux et position (ADR-14, POS-14) : où le suivi en est, et chaque
// lieu connu avec son adresse, sa nature, son mode et sa description, celle que
// HAL lit pour choisir le lieu d'une séance. Seule l'adresse se corrige ici
// (ADR-6) ; le reste se dit à HAL.

struct EcranAdresses: View {
    @Environment(\.openURL) private var ouvrir
    @State private var suivi = SuiviPosition.partage
    @State private var aCorriger: SuiviPosition.Lieu?
    @State private var charge = false

    var body: some View {
        FormulaireVerre {
            Section {
                LigneReglage(icone: "location", couleur: Categorie.perso.couleur,
                             libelle: "Suivi de la position", accessoire: .valeur(etatDuSuivi),
                             sousTitre: ouJeSuis)
                if suivi.autorisation == .notDetermined || suivi.autorisation == .authorizedWhenInUse {
                    Button(suivi.autorisation == .notDetermined ? "Activer le suivi" : "Passer à « Toujours »") {
                        suivi.activer()
                    }
                    .buttonStyle(.hal(.accent, pleineLargeur: true))
                } else if !suivi.enMarche {
                    Button("Ouvrir les réglages d'iOS") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { ouvrir(url) }
                    }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                }
            } header: {
                Text("Position")
            } footer: {
                Text("Un cercle de 50 m autour de chaque lieu. Le serveur garde le lieu où tu es, jamais tes trajets.")
            }

            Section {
                if !charge {
                    ProgressView().frame(maxWidth: .infinity)
                } else if suivi.lieux.isEmpty {
                    Text("Aucune adresse. Dis-les à HAL : « ma salle est au 15 rue…, ouverte 24 h sur 24 », « à Lusse je suis chez mes parents ».")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                }
                ForEach(suivi.lieux) { lieu in
                    Button { aCorriger = lieu } label: { LigneLieu(lieu: lieu) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("Mes adresses")
            } footer: {
                Text("Chaque lieu de sport vaut pour toutes tes séances : HAL choisit d'après sa description. Pour la changer, dis-le à HAL.")
            }
        }
        .navigationTitle("Lieux et position")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, lieux et position")
        .sheet(item: $aCorriger) { lieu in
            CorrigerAdresse(lieu: lieu) { Task { await suivi.rafraichirLesCercles() } }
                .presentationDetents([.medium])
                .feuilleEnVerre()
        }
        .task {
            await suivi.rafraichirLesCercles()
            charge = true
        }
    }

    private var etatDuSuivi: String {
        switch suivi.autorisation {
        case .authorizedAlways: suivi.precise ? "En marche" : "Approximative"
        case .authorizedWhenInUse: "Appli ouverte"
        case .denied, .restricted: "Refusé"
        default: "À activer"
        }
    }

    private var ouJeSuis: String? {
        guard let etat = suivi.etat, etat.sue else { return nil }
        let ou = etat.lieu.map { "À \($0)" } ?? "Ailleurs"
        guard let depuis = etat.depuis else { return ou }
        return "\(ou) depuis \(EnFrancais.heure(depuis))"
    }
}

/// Une adresse : son nom, sa nature et son mode, l'adresse, et la mémoire.
private struct LigneLieu: View {
    let lieu: SuiviPosition.Lieu

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Pastille(icone: icone, couleur: Categorie.perso.couleur)
            VStack(alignment: .leading, spacing: 3) {
                Text(lieu.nom).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Text(lieu.adresse).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                Text(details).texte(.legende).foregroundStyle(Palette.texteTertiaire)
                if let description = lieu.description, !description.isEmpty {
                    Text(description).texte(.legende)
                        .foregroundStyle(Categorie.ia.couleur).lineLimit(4)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "pencil").foregroundStyle(Palette.texteTertiaire)
        }
        .contentShape(Rectangle())
        .accessibilityHint("Corriger l'adresse")
    }

    private var icone: String {
        switch lieu.nature {
        case "foyer": "house"
        case "sport": "dumbbell"
        case "etudes": "graduationcap"
        case "travail": "briefcase"
        case "sejour": "bed.double"
        default: "mappin"
        }
    }

    private var details: String {
        let nature = switch lieu.nature {
        case "foyer": "Le foyer"
        case "sport": "Sport"
        case "etudes": "Études"
        case "travail": "Travail"
        case "sejour": "On y dort"
        default: "Autre"
        }
        let mode = switch lieu.modeTrajet {
        case "velo": "à vélo"
        case "voiture": "en voiture"
        default: "à pied"
        }
        var morceaux = [nature, mode]
        if let foyer = lieu.trajetsDepuis?.first(where: { $0.depuis != lieu.nom }) {
            morceaux.append("\(foyer.minutes) min depuis \(foyer.depuis)")
        }
        return morceaux.joined(separator: " · ")
    }
}

/// ADR-6 : l'adresse corrigée est cherchée par le serveur avant d'être gardée.
private struct CorrigerAdresse: View {
    let lieu: SuiviPosition.Lieu
    let apres: () -> Void
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var adresse = ""
    @State private var erreur: String?
    @State private var envoi = false

    var body: some View {
        NavigationStack {
            FormulaireVerre {
                Section {
                    TextField("Numéro, rue, ville", text: $adresse, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                } header: {
                    Text(lieu.nom)
                }
                LigneErreur(texte: erreur)
            }
            .navigationTitle("Adresse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { Task { await enregistrer() } }
                        .disabled(envoi || adresse.trimmingCharacters(in: .whitespaces).count < 3)
                }
            }
        }
        .onAppear { adresse = lieu.adresse }
    }

    private struct Correction: Encodable { var adresse: String }

    private func enregistrer() async {
        envoi = true
        defer { envoi = false }
        erreur = nil
        do {
            try await foyer.agir("PATCH", "appli/lieux/\(lieu.idLieuConnu)",
                                 corps: ClientAPI.corps(Correction(adresse: adresse)))
            apres()
            fermer()
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
