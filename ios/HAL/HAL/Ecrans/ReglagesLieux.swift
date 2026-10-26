import SwiftUI

// Réglages, Lieux et position (ADR-14, POS-14) : où le suivi en est, et chaque
// lieu connu avec son adresse, sa nature, son mode et sa description, celle que
// HAL lit pour choisir le lieu d'une séance. Chaque adresse s'ouvre dans une
// fiche, avec les champs du démarrage (DEM-7), et s'y modifie ; on en ajoute
// d'autres au même endroit (ADR-6).

struct EcranAdresses: View {
    @Environment(\.openURL) private var ouvrir
    @State private var suivi = SuiviPosition.partage
    @State private var fiche: FicheAdresse.Sujet?
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
                    Text("Aucune adresse pour l'instant. Commence par ton foyer : c'est de lui que partent les trajets.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                }
                ForEach(suivi.lieux) { lieu in
                    Button { fiche = .modifier(lieu) } label: { LigneLieu(lieu: lieu) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("Mes adresses")
            } footer: {
                Text("Chaque lieu de sport vaut pour toutes tes séances : HAL choisit d'après sa description. Touche une adresse pour la modifier.")
            }

            if charge {
                Section {
                    if !suivi.lieux.contains(where: { $0.nature == "foyer" }) {
                        Button("Ajouter l'adresse du foyer", systemImage: "house") {
                            fiche = .ajouter("foyer")
                        }
                    }
                    Button("Ajouter un lieu de sport", systemImage: "dumbbell") {
                        fiche = .ajouter("sport")
                    }
                    Button("Ajouter une autre adresse", systemImage: "mappin") {
                        fiche = .ajouter("sejour")
                    }
                }
            }
        }
        .navigationTitle("Lieux et position")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, lieux et position")
        .sheet(item: $fiche) { sujet in
            FicheAdresse(sujet: sujet) { await suivi.rafraichirLesCercles() }
                .presentationDetents([.large])
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
        .accessibilityHint("Modifier l'adresse")
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

/// DEM-7, ADR-6 : une adresse, avec les champs du démarrage. L'adresse est
/// cherchée par le serveur avant d'être gardée ; introuvable, elle est dite ici.
/// Le foyer et un lieu de sport restent ce qu'ils sont ; une autre adresse dit
/// ce qu'elle est.
struct FicheAdresse: View {
    enum Sujet: Identifiable {
        case modifier(SuiviPosition.Lieu)
        case ajouter(String)

        var id: String {
            switch self {
            case .modifier(let lieu): "lieu-\(lieu.idLieuConnu)"
            case .ajouter(let nature): "nouveau-\(nature)"
            }
        }
    }

    let sujet: Sujet
    let apres: () async -> Void
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var nom = ""
    @State private var adresse = ""
    @State private var nature = "sejour"
    @State private var description = ""
    @State private var erreur: String?
    @State private var envoi = false

    private var lieu: SuiviPosition.Lieu? {
        if case .modifier(let lieu) = sujet { return lieu }
        return nil
    }

    var body: some View {
        NavigationStack {
            FormulaireVerre {
                Section {
                    if nature != "foyer" {
                        TextField(nature == "sport" ? "Nom : Basic-Fit centre, piscine…"
                                                    : "Nom : chez mes parents…", text: $nom)
                    }
                    TextField("Numéro, rue, ville", text: $adresse, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                } header: {
                    Text(titreDuGroupe)
                }
                if !["foyer", "sport"].contains(nature) {
                    Section {
                        Picker("C'est", selection: $nature) {
                            Text("J'y dors").tag("sejour")
                            Text("L'école").tag("etudes")
                            Text("Le travail").tag("travail")
                            Text("Autre").tag("autre")
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section {
                    TextField(nature == "sport" ? "Horaires, affluence, ce que tu y fais"
                                                : "Ce que tu y fais", text: $description,
                              axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Description")
                } footer: {
                    Text("HAL la lit pour choisir où placer une séance. Vide, elle s'efface.")
                }
                LigneErreur(texte: erreur)
            }
            .navigationTitle(lieu == nil ? "Nouvelle adresse" : "Adresse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { Task { await enregistrer() } }
                        .disabled(envoi || adresse.trimmingCharacters(in: .whitespaces).count < 3)
                }
            }
        }
        .onAppear(perform: remplir)
    }

    private var titreDuGroupe: String {
        switch nature {
        case "foyer": "Ton foyer"
        case "sport": "Lieu de sport"
        default: "Autre adresse"
        }
    }

    private func remplir() {
        switch sujet {
        case .modifier(let lieu):
            nom = lieu.nom
            adresse = lieu.adresse
            nature = lieu.nature
            description = lieu.description ?? ""
        case .ajouter(let nouvelle):
            nature = nouvelle
            nom = nouvelle == "foyer" ? "Chez nous" : ""
        }
    }

    private struct Modification: Encodable {
        var nom: String?
        var adresse: String?
        var nature: String?
        var description: String?
    }

    private struct NouveauLieu: Encodable {
        var nom: String
        var adresse: String
        var nature: String
        var description: String?
    }

    private func enregistrer() async {
        envoi = true
        defer { envoi = false }
        erreur = nil
        let nom = nom.trimmingCharacters(in: .whitespaces)
        let adresse = adresse.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let lieu {
                // Seul ce qui a changé part : une adresse inchangée n'est pas recherchée.
                let changement = Modification(
                    nom: !nom.isEmpty && nom != lieu.nom ? nom : nil,
                    adresse: adresse != lieu.adresse ? adresse : nil,
                    nature: nature != lieu.nature ? nature : nil,
                    description: description != (lieu.description ?? "") ? description : nil)
                try await foyer.agir("PATCH", "appli/lieux/\(lieu.idLieuConnu)",
                                     corps: ClientAPI.corps(changement))
            } else {
                let parDefaut = switch nature {
                case "foyer": "Chez nous"
                case "sport": "Ma salle"
                default: "Autre adresse"
                }
                try await foyer.agir("POST", "appli/lieux", corps: ClientAPI.corps(
                    NouveauLieu(nom: nom.isEmpty ? parDefaut : nom, adresse: adresse,
                                nature: nature, description: description.isEmpty ? nil : description)))
            }
            await apres()
            fermer()
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
