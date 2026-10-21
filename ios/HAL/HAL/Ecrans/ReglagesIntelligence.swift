import SwiftUI
import UIKit

// Réglages, Intelligence (FOU-18, partie F) : qui fait réfléchir HAL, en trois
// options toujours affichées (abonnement Claude, API d'Anthropic, Gemini), chacune
// avec son état et son interrupteur ; puis les clients MCP qui lisent HAL depuis
// un ordinateur, leurs clés et leurs dernières sessions.

private let enFrancais = Locale(identifier: "fr_FR")

private func motifDe(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

/// Une clé de client MCP, telle que `GET /moi/cles-mcp` la rend (MCP-2).
struct CleMCP: Codable, Identifiable, Hashable, Sendable {
    let idCle: Int
    let nom: String
    let creeLe: Date
    let dernierUsage: Date?
    let revoqueeLe: Date?
    var id: Int { idCle }
}

/// Une clé qui vient d'être créée : la seule fois où elle est montrée.
struct CleMCPCreee: Codable, Sendable {
    struct Commandes: Codable, Sendable {
        let claudeCode: String?
        let geminiCli: String?
    }
    let idCle: Int
    let nom: String
    let cle: String
    let adresse: String?
    let commandes: Commandes?
}

/// Une session d'un client MCP (MCP-10).
struct SessionMCP: Codable, Identifiable, Hashable, Sendable {
    let idSession: String
    let client: String
    let cle: String
    let debut: Date
    let dernierAppel: Date
    let appels: Int
    var id: String { idSession }
}

/// Un fournisseur du modèle, tel que `GET /moi/fournisseurs` le rend (FOU-1).
struct FournisseurModele: Codable, Identifiable, Hashable, Sendable {
    let idFournisseur: Int
    let type: String
    let rang: Int
    let secretFin: String?
    let etat: String
    let deCoteJusquA: Date?
    let motif: String?
    let plafondMensuel: Double?
    let libelle: String
    var id: Int { idFournisseur }
}

struct EtatDesFournisseurs: Codable, Sendable {
    let fournisseurs: [FournisseurModele]
    let depenseApiDuMois: Double
    let cleDuServeur: Bool
    let chiffrementRegle: Bool
    /// FOU-17 : Gemini CLI est dans l'image du serveur. Absent d'un serveur plus ancien.
    let geminiInstalle: Bool?
}

/// Intelligence : qui fait réfléchir HAL, et les clients MCP qui le lisent.
struct EcranIntelligence: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var cles: [CleMCP]?
    @State private var sessions: [SessionMCP] = []
    @State private var nom = ""
    @State private var creee: CleMCPCreee?
    @State private var aRevoquer: CleMCP?
    @State private var envoi = false
    @State private var erreur: String?
    @State private var modele: EtatDesFournisseurs?
    @State private var jeton = ""
    @State private var cleAPI = ""
    @State private var identifiantsGemini = ""
    @State private var plafond = ""
    @State private var aRetirer: FournisseurModele?
    /// L'option dont le formulaire est ouvert sous sa ligne.
    @State private var ouvert: String?
    @State private var erreurModele: String?

    private struct NouvelleCle: Encodable { let nom: String }
    private struct Branchement: Encodable { let secret: String?; let plafond: Double? }
    private struct Ordre: Encodable { let ordre: [String] }
    private struct Plafond: Encodable { let plafond: Double }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                if !foyer.connecte {
                    Text("Connecte-toi à ton serveur pour brancher un client.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    sectionModele

                    if let creee { carteCreee(creee) }

                    EnTeteGroupe(texte: "Clients sur ton ordinateur")
                    if let cles {
                        let vivantes = cles.filter { $0.revoqueeLe == nil }
                        if vivantes.isEmpty {
                            Text("Aucun client branché pour l'instant.")
                                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        }
                        ForEach(vivantes) { ligne(cle: $0) }
                        let revoquees = cles.count - vivantes.count
                        if revoquees > 0 {
                            Text("\(revoquees) clé\(revoquees > 1 ? "s" : "") révoquée\(revoquees > 1 ? "s" : "")")
                                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    }

                    EnTeteGroupe(texte: "Ajouter un client")
                    TextField("Son nom : « Claude Code du Mac »", text: $nom)
                        .texte(.corps).foregroundStyle(Palette.textePrincipal)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .verreControle(Capsule(), interactif: false)
                    Button("Créer sa clé") { Task { await creer() } }
                        .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                        .disabled(nom.trimmingCharacters(in: .whitespaces).isEmpty || envoi)

                    if !sessions.isEmpty {
                        EnTeteGroupe(texte: "Dernières sessions")
                        VStack(spacing: 0) {
                            ForEach(Array(sessions.prefix(8).enumerated()), id: \.element.id) { rang, session in
                                if rang > 0 { Divider().overlay(Palette.verreBord) }
                                ligne(session: session)
                            }
                        }
                        .carte(rayon: Rayon.controle)
                    }

                    LigneErreur(texte: erreur)
                }
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .margeDeLaBarre()
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Intelligence")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, intelligence")
        .task { await charger() }
        .refreshable { await charger() }
        .confirmationDialog("Révoquer « \(aRevoquer?.nom ?? "") » ?",
                            isPresented: Binding { aRevoquer != nil } set: { if !$0 { aRevoquer = nil } },
                            titleVisibility: .visible) {
            Button("Révoquer", role: .destructive) {
                if let cle = aRevoquer { Task { await revoquer(cle) } }
            }
        }
        .confirmationDialog("Retirer « \(aRetirer?.libelle ?? "") » ?",
                            isPresented: Binding { aRetirer != nil } set: { if !$0 { aRetirer = nil } },
                            titleVisibility: .visible) {
            Button("Retirer", role: .destructive) {
                if let f = aRetirer { Task { await modifier("DELETE", "moi/fournisseurs/\(f.type)", nil, "Retiré") } }
            }
        }
    }

    // MARK: - Qui fait réfléchir HAL (FOU-1 à FOU-9)

    private struct Option: Hashable {
        let type: String
        let titre: String
        let icone: String
    }

    /// Les trois façons de faire réfléchir HAL, toujours affichées, dans cet ordre.
    private static let options = [
        Option(type: "claude_code", titre: "Abonnement Claude", icone: "person.badge.key"),
        Option(type: "api", titre: "API d'Anthropic", icone: "creditcard"),
        Option(type: "gemini_cli", titre: "Gemini", icone: "sparkles"),
    ]

    @ViewBuilder private var sectionModele: some View {
        EnTeteGroupe(texte: "Qui fait réfléchir HAL")
        if let modele {
            if toutEstCoupe(modele) {
                Text("Tout est coupé : HAL ne peut pas répondre.")
                    .texte(.legende).foregroundStyle(Categorie.alerte.couleur)
            }
            if !modele.chiffrementRegle {
                Text("Le serveur ne peut pas garder de jeton : HAL_CLE_CHIFFREMENT manque dans son .env.")
                    .texte(.legende).foregroundStyle(Categorie.alerte.couleur)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Self.options, id: \.type) { option in
                ligneOption(option.type, option.titre, option.icone, modele)
                if ouvert == option.type || doitEtreRecolle(option.type, modele) {
                    formulaire(option.type, modele)
                }
            }
        } else if let erreurModele {
            Text("Impossible de lire tes fournisseurs : \(erreurModele)")
                .texte(.legende).foregroundStyle(Categorie.alerte.couleur)
                .fixedSize(horizontal: false, vertical: true)
            Button("Réessayer") { Task { await charger() } }
                .buttonStyle(.hal(.verre, pleineLargeur: true))
        } else if foyer.connecte {
            ProgressView().frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    /// FOU-8 : plus rien dans la chaîne. L'ordre se lit aux numéros des lignes.
    private func toutEstCoupe(_ modele: EtatDesFournisseurs) -> Bool {
        !modele.cleDuServeur
            && !modele.fournisseurs.contains { $0.etat == "actif" || $0.etat == "de_cote" }
    }

    private func fournisseur(_ type: String, _ modele: EtatDesFournisseurs) -> FournisseurModele? {
        modele.fournisseurs.first { $0.type == type }
    }

    private func doitEtreRecolle(_ type: String, _ modele: EtatDesFournisseurs) -> Bool {
        fournisseur(type, modele)?.etat == "a_reconnecter"
    }

    /// L'API passe par la clé du serveur tant que le compte n'a rien branché (FOU-1).
    private func apiImplicite(_ type: String, _ modele: EtatDesFournisseurs) -> Bool {
        type == "api" && modele.cleDuServeur
    }

    private func estActive(_ type: String, _ modele: EtatDesFournisseurs) -> Bool {
        if apiImplicite(type, modele) { return true }
        guard let f = fournisseur(type, modele) else { return false }
        return f.etat == "actif" || f.etat == "de_cote"
    }

    private func ligneOption(_ type: String, _ titre: String, _ icone: String,
                             _ modele: EtatDesFournisseurs) -> some View {
        let f = fournisseur(type, modele)
        let active = estActive(type, modele)
        let alerte = f?.etat == "a_reconnecter" || (type == "gemini_cli" && f == nil && modele.geminiInstalle != true)
        return HStack(spacing: 12) {
            Pastille(icone: icone, couleur: active ? Categorie.ia.couleur : Palette.texteSecondaire)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.map { "\($0.rang). \(titre)" } ?? titre)
                    .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Label(etatOption(type, f, modele), systemImage: active ? "circle.fill" : "circle")
                    .labelStyle(PuceEtat(couleur: alerte ? Categorie.alerte.couleur
                                         : active ? Categorie.sport.couleur : Palette.texteTertiaire))
                    .texte(.legende)
                    .foregroundStyle(alerte ? Categorie.alerte.couleur : Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let f {
                Menu {
                    if f.rang > 1 {
                        Button("Passer devant", systemImage: "arrow.up") { Task { await monter(f) } }
                    }
                    Button(type == "api" ? "Changer la clé" : "Recoller le jeton", systemImage: "key") {
                        withAnimation(.smooth) { ouvert = type }
                    }
                    if type == "api" {
                        Button("Plafond à 5 $", systemImage: "dollarsign") { Task { await regler(5) } }
                        Button("Plafond à 10 $", systemImage: "dollarsign") { Task { await regler(10) } }
                        Button("Plafond à 20 $", systemImage: "dollarsign") { Task { await regler(20) } }
                    }
                    Button("Retirer", systemImage: "trash", role: .destructive) { aRetirer = f }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Palette.texteSecondaire)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Options de \(titre)")
            }
            Toggle(titre, isOn: Binding(
                get: { active },
                set: { voulu in Task { await basculer(type, voulu, modele) } }))
                .labelsHidden()
                .tint(Categorie.ia.couleur)
                .disabled(envoi || (type == "gemini_cli" && f == nil && modele.geminiInstalle != true))
        }
        .padding(Espace.interne)
        .carte(rayon: Rayon.controle)
    }

    /// Ce que l'option fait en ce moment, en clair.
    private func etatOption(_ type: String, _ f: FournisseurModele?, _ modele: EtatDesFournisseurs) -> String {
        if apiImplicite(type, modele) {
            return String(format: "En marche · clé du serveur · %.2f $ ce mois-ci", modele.depenseApiDuMois)
                .replacingOccurrences(of: ".", with: ",")
        }
        guard let f else {
            if type == "gemini_cli" && modele.geminiInstalle != true {
                return "Pas installé sur le serveur"
            }
            return "Pas branché"
        }
        var morceaux: [String] = []
        switch f.etat {
        case "actif": morceaux.append("En marche")
        case "de_cote":
            morceaux.append(f.deCoteJusquA.map {
                "En pause jusqu'à \($0.formatted(.dateTime.hour().minute().locale(enFrancais)))"
            } ?? "En pause")
        case "a_reconnecter": morceaux.append("Jeton refusé : à recoller")
        case "coupe": morceaux.append("Branché, désactivé")
        default: morceaux.append(f.etat)
        }
        if let motif = f.motif, f.etat == "de_cote" { morceaux.append(motif) }
        if type == "api" {
            let plafond = f.plafondMensuel ?? 10
            morceaux.append(String(format: "%.2f $ sur %.0f $ ce mois-ci", modele.depenseApiDuMois, plafond)
                .replacingOccurrences(of: ".", with: ","))
        }
        if let fin = f.secretFin { morceaux.append("…\(fin)") } else if type == "api" { morceaux.append("clé du serveur") }
        return morceaux.joined(separator: " · ")
    }

    /// L'interrupteur d'une option : la remettre dans la chaîne, l'en sortir, ou
    /// ouvrir de quoi la brancher si elle ne l'est pas encore.
    private func basculer(_ type: String, _ voulu: Bool, _ modele: EtatDesFournisseurs) async {
        if let f = fournisseur(type, modele) {
            if voulu, f.etat == "a_reconnecter" {
                withAnimation(.smooth) { ouvert = type }
            } else if voulu {
                await modifier("POST", "moi/fournisseurs/\(type)/reprendre", nil, "Activé")
            } else {
                await modifier("POST", "moi/fournisseurs/\(type)/couper", nil, "Désactivé")
            }
            return
        }
        if voulu {
            withAnimation(.smooth) { ouvert = ouvert == type ? nil : type }
            return
        }
        // La clé du serveur, utilisée tant que rien n'est branché.
        guard apiImplicite(type, modele) else { return }
        if foyer.moi.estAdministrateur {
            envoi = true
            defer { envoi = false }
            do {
                let _: EtatDesFournisseurs = try await foyer.demander(
                    "PUT", "moi/fournisseurs/api",
                    corps: ClientAPI.corps(Branchement(secret: nil, plafond: nil)))
                self.modele = try await foyer.demander("POST", "moi/fournisseurs/api/couper")
                erreur = nil
                annoncer("API désactivée")
            } catch {
                erreur = motifDe(error)
            }
        } else {
            erreur = "La clé du serveur sert tant que tu n'as rien branché : active d'abord ton abonnement Claude ou Gemini."
        }
    }

    /// Ce qu'il faut coller pour brancher une option, sous sa ligne.
    @ViewBuilder
    private func formulaire(_ type: String, _ modele: EtatDesFournisseurs) -> some View {
        switch type {
        case "claude_code":
            VStack(alignment: .leading, spacing: 10) {
                Text("Sur ton ordinateur : `claude setup-token`, puis colle le jeton (sk-ant-oat01-…).")
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
                champSecret("Jeton d'abonnement", $jeton)
                HStack(spacing: 10) {
                    Button("Coller") { if let colle = UIPasteboard.general.string { jeton = colle } }
                        .buttonStyle(.hal(.verre, pleineLargeur: true))
                    Button("Brancher") { Task { await brancher("claude_code", jeton, nil) } }
                        .buttonStyle(.hal(.accent, pleineLargeur: true))
                        .disabled(!jeton.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-ant-") || envoi)
                }
            }
            .padding(Espace.interne)
            .carte(rayon: Rayon.controle)
        case "api":
            VStack(alignment: .leading, spacing: 10) {
                champSecret(foyer.moi.estAdministrateur ? "Clé d'API (vide : celle du serveur)" : "Clé d'API", $cleAPI)
                TextField("Plafond du mois, en $ (10 par défaut)", text: $plafond)
                    .keyboardType(.decimalPad)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .padding(.horizontal, 14).frame(height: 46)
                    .verreControle(Capsule(), interactif: false)
                Button("Brancher l'API") {
                    Task { await brancher("api", cleAPI, Double(plafond.replacingOccurrences(of: ",", with: "."))) }
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true))
                .disabled(envoi || (cleAPI.isEmpty && !foyer.moi.estAdministrateur))
            }
            .padding(Espace.interne)
            .carte(rayon: Rayon.controle)
        default:
            CarteGemini(texte: $identifiantsGemini,
                        installe: modele.geminiInstalle ?? false,
                        aRecoller: doitEtreRecolle("gemini_cli", modele),
                        envoi: envoi,
                        brancher: { Task { await brancher("gemini_cli", identifiantsGemini, nil) } },
                        copier: copier)
        }
    }

    private func champSecret(_ titre: String, _ valeur: Binding<String>) -> some View {
        SecureField(titre, text: valeur)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .texte(.corps).foregroundStyle(Palette.textePrincipal)
            .padding(.horizontal, 14).frame(height: 46)
            .verreControle(Capsule(), interactif: false)
    }

    private func brancher(_ type: String, _ secret: String, _ plafond: Double?) async {
        envoi = true
        defer { envoi = false }
        let propre = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            modele = try await foyer.demander(
                "PUT", "moi/fournisseurs/\(type)",
                corps: ClientAPI.corps(Branchement(secret: propre.isEmpty ? nil : propre, plafond: plafond)))
            jeton = ""; cleAPI = ""; identifiantsGemini = ""; self.plafond = ""
            erreur = nil
            withAnimation(.smooth) { ouvert = nil }
            annoncer(type == "api" ? "API branchée en secours"
                     : type == "gemini_cli" ? "Gemini branché" : "Abonnement branché")
        } catch {
            erreur = motifDe(error)
        }
    }

    private func modifier(_ methode: String, _ chemin: String, _ corps: Data?, _ annonce: String) async {
        do {
            modele = try await foyer.demander(methode, chemin, corps: corps)
            erreur = nil
            annoncer(annonce)
        } catch {
            erreur = motifDe(error)
        }
    }

    private func monter(_ f: FournisseurModele) async {
        guard var types = modele?.fournisseurs.map(\.type),
              let rang = types.firstIndex(of: f.type), rang > 0 else { return }
        types.swapAt(rang, rang - 1)
        await modifier("PUT", "moi/fournisseurs/ordre", ClientAPI.corps(Ordre(ordre: types)), "Ordre changé")
    }

    private func regler(_ montant: Double) async {
        await modifier("PUT", "moi/fournisseurs/api/plafond", ClientAPI.corps(Plafond(plafond: montant)),
                       "Plafond à \(Int(montant)) $")
    }

    /// Une clé vivante : son nom, sa dernière utilisation, et de quoi la révoquer.
    private func ligne(cle: CleMCP) -> some View {
        HStack(spacing: 12) {
            Pastille(icone: "key", couleur: Categorie.ia.couleur)
            VStack(alignment: .leading, spacing: 1) {
                Text(cle.nom).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Label(cle.dernierUsage.map { "Active · utilisée \(quand($0))" } ?? "Active · jamais utilisée",
                      systemImage: "circle.fill")
                    .labelStyle(PuceEtat(couleur: Categorie.sport.couleur))
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            Spacer()
            Menu {
                Button("Révoquer", systemImage: "trash", role: .destructive) { aRevoquer = cle }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Palette.texteSecondaire)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Options de \(cle.nom)")
        }
        .padding(Espace.interne)
        .carte(rayon: Rayon.controle)
    }

    private func ligne(session: SessionMCP) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.client).texte(.corps).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                Text("\(session.cle) · \(quand(session.dernierAppel))")
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
            }
            Spacer()
            Text("\(session.appels) outil\(session.appels > 1 ? "s" : "")")
                .texte(.legende).monospacedDigit().foregroundStyle(Palette.texteSecondaire)
        }
        .padding(.horizontal, Espace.interne)
        .padding(.vertical, 10)
    }

    /// F.8.3 : la clé n'est montrée qu'ici, avec ce qu'il faut copier pour brancher le client.
    private func carteCreee(_ creee: CleMCPCreee) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CLÉ DE « \(creee.nom.uppercased()) »").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
            Text("Elle ne sera plus jamais affichée. Copie la commande dans le terminal de ton ordinateur.")
                .texte(.corps).foregroundStyle(Palette.textePrincipal)
                .fixedSize(horizontal: false, vertical: true)
            if let commande = creee.commandes?.claudeCode {
                Text(commande)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Palette.textePrincipal)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("Copier la commande Claude Code") { copier(commande, "Commande copiée") }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
            }
            if let gemini = creee.commandes?.geminiCli {
                Button("Copier la commande Gemini CLI") { copier(gemini, "Commande copiée") }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
            }
            Button("Copier la clé seule") { copier(creee.cle, "Clé copiée") }
                .buttonStyle(.hal(.verre, pleineLargeur: true))
            if creee.adresse == nil {
                Text("Le serveur ne connaît pas son adresse publique (HOTE_PUBLIC) : la commande est à compléter avec l'adresse de /mcp.")
                    .texte(.legende).foregroundStyle(Categorie.alerte.couleur)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("C'est fait") { withAnimation(.smooth) { self.creee = nil } }
                .buttonStyle(.hal(.accent, pleineLargeur: true))
        }
        .padding(Espace.interne)
        .carte()
    }

    private func quand(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named).locale(enFrancais))
    }

    private func copier(_ texte: String, _ annonce: String) {
        UIPasteboard.general.string = texte
        annoncer(annonce)
    }

    /// Chaque partie se lit seule : un serveur qui ne sait pas encore répondre à
    /// l'une n'empêche pas les autres de s'afficher.
    private func charger() async {
        guard foyer.connecte else { return }
        do {
            modele = try await foyer.demander("GET", "moi/fournisseurs")
            erreurModele = nil
        } catch {
            erreurModele = motifDe(error)
        }
        do {
            cles = try await foyer.demander("GET", "moi/cles-mcp")
            sessions = try await foyer.demander("GET", "moi/sessions-mcp")
        } catch {
            cles = cles ?? []
            erreur = motifDe(error)
        }
    }

    private func creer() async {
        envoi = true
        defer { envoi = false }
        do {
            let nouvelle: CleMCPCreee = try await foyer.demander(
                "POST", "moi/cles-mcp",
                corps: ClientAPI.corps(NouvelleCle(nom: nom.trimmingCharacters(in: .whitespaces))))
            withAnimation(.smooth) { creee = nouvelle }
            nom = ""
            await charger()
        } catch {
            erreur = motifDe(error)
        }
    }

    private func revoquer(_ cle: CleMCP) async {
        do {
            try await foyer.agir("DELETE", "moi/cles-mcp/\(cle.idCle)")
            if creee?.idCle == cle.idCle { creee = nil }
            annoncer("« \(cle.nom) » révoquée")
            await charger()
        } catch {
            erreur = motifDe(error)
        }
    }
}

/// Une pastille de couleur devant l'état d'une option : verte en marche, grise sinon.
private struct PuceEtat: LabelStyle {
    let couleur: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(couleur)
            configuration.title
        }
    }
}
