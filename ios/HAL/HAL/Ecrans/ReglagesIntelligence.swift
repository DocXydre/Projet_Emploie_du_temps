import SwiftUI
import UIKit

// Réglages, Intelligence (FOU-19, partie F) : qui fait réfléchir HAL (son
// abonnement Claude, puis l'API en secours), et les clients MCP qui lisent HAL
// depuis un ordinateur, leurs clés et leurs dernières sessions.

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
    /// FOU-17 : Gemini CLI n'est proposé qu'une fois validé sur le serveur.
    let geminiPropose: Bool?
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

    private struct NouvelleCle: Encodable { let nom: String }
    private struct Branchement: Encodable { let secret: String?; let plafond: Double? }
    private struct Ordre: Encodable { let ordre: [String] }
    private struct Plafond: Encodable { let plafond: Double }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                HStack(spacing: 12) {
                    Pastille(icone: "terminal", couleur: Categorie.ia.couleur)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HAL depuis ton ordinateur").texte(.titreWidget)
                            .foregroundStyle(Palette.textePrincipal)
                        Text("Claude Code, Gemini CLI ou Claude Desktop lisent ton planning, la maison, tes séances et la mémoire de HAL. Ils ne changent rien sans toi.")
                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Espace.interne)
                .carte()

                if !foyer.connecte {
                    Text("Connecte-toi à ton serveur pour brancher un client.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    sectionModele

                    if let creee { carteCreee(creee) }

                    EnTeteGroupe(texte: "Clients")
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
                    Text("Une clé n'ouvre que la lecture de HAL, sa mémoire et tes mesures. Elle se révoque seule, sans déconnecter ce téléphone (MCP-2).")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire)
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
        .confirmationDialog("Révoquer « \(aRevoquer?.nom ?? "") » ?",
                            isPresented: Binding { aRevoquer != nil } set: { if !$0 { aRevoquer = nil } },
                            titleVisibility: .visible) {
            Button("Révoquer", role: .destructive) {
                if let cle = aRevoquer { Task { await revoquer(cle) } }
            }
        } message: {
            Text("Ce client ne pourra plus lire HAL. Les autres clients et ce téléphone ne changent pas.")
        }
        .confirmationDialog("Retirer « \(aRetirer?.libelle ?? "") » ?",
                            isPresented: Binding { aRetirer != nil } set: { if !$0 { aRetirer = nil } },
                            titleVisibility: .visible) {
            Button("Retirer", role: .destructive) {
                if let f = aRetirer { Task { await modifier("DELETE", "moi/fournisseurs/\(f.type)", nil, "Retiré") } }
            }
        } message: {
            Text("Son jeton ou sa clé est effacé du serveur (FOU-3).")
        }
    }

    // MARK: - Qui fait réfléchir HAL (FOU-1 à FOU-9)

    @ViewBuilder private var sectionModele: some View {
        EnTeteGroupe(texte: "Qui fait réfléchir HAL")
        if let modele {
            if modele.fournisseurs.isEmpty {
                Text("HAL passe par l'API du serveur. Branche ton abonnement Claude pour qu'il passe d'abord par lui, sans coût en plus.")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(modele.fournisseurs) { ligne(fournisseur: $0, total: modele.fournisseurs.count) }
            if !modele.chiffrementRegle {
                Text("Le serveur ne peut pas garder de jeton : HAL_CLE_CHIFFREMENT manque dans son .env.")
                    .texte(.legende).foregroundStyle(Categorie.alerte.couleur)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !modele.fournisseurs.contains(where: { $0.type == "claude_code" }) || jetonARecoller {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ton abonnement Claude").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Text("Sur ton ordinateur, lance `claude setup-token`, puis colle le jeton ici. Il n'est essayé qu'une fois, puis gardé chiffré.")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                    champSecret("Jeton d'abonnement", $jeton)
                    Button("Brancher mon abonnement") {
                        Task { await brancher("claude_code", jeton, nil) }
                    }
                    .buttonStyle(.hal(.accent, pleineLargeur: true))
                    .disabled(jeton.trimmingCharacters(in: .whitespaces).count < 20 || envoi)
                }
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
            }
            if !modele.fournisseurs.contains(where: { $0.type == "api" }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("L'API en secours").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Text("Quand l'abonnement est épuisé, HAL passe par l'API avec ta clé, jusqu'au plafond du mois.")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                    champSecret(foyer.moi.estAdministrateur ? "Clé d'API (vide : celle du serveur)" : "Clé d'API", $cleAPI)
                    TextField("Plafond du mois, en $ (10 par défaut)", text: $plafond)
                        .keyboardType(.decimalPad)
                        .texte(.corps).foregroundStyle(Palette.textePrincipal)
                        .padding(.horizontal, 14).frame(height: 46)
                        .verreControle(Capsule(), interactif: false)
                    Button("Ajouter l'API en secours") {
                        Task { await brancher("api", cleAPI, Double(plafond.replacingOccurrences(of: ",", with: "."))) }
                    }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                    .disabled(envoi || (cleAPI.isEmpty && !foyer.moi.estAdministrateur))
                }
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
            }
            if modele.geminiPropose == true,
               !modele.fournisseurs.contains(where: { $0.type == "gemini_cli" }) || aRecoller("gemini_cli") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Gemini, avec ton compte Google").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Text("Sur ton ordinateur, lance `gemini` et connecte-toi avec Google, puis colle ici le contenu du fichier ~/.gemini/oauth_creds.json. Une clé de l'API Gemini (AIza…) marche aussi.")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                    champSecret("Identifiants Gemini", $identifiantsGemini)
                    Button("Brancher Gemini") {
                        Task { await brancher("gemini_cli", identifiantsGemini, nil) }
                    }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                    .disabled(identifiantsGemini.trimmingCharacters(in: .whitespaces).count < 20 || envoi)
                }
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
            }
        } else if foyer.connecte {
            ProgressView().frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    private var jetonARecoller: Bool { aRecoller("claude_code") }

    private func aRecoller(_ type: String) -> Bool {
        modele?.fournisseurs.contains { $0.type == type && $0.etat == "a_reconnecter" } ?? false
    }

    private func champSecret(_ titre: String, _ valeur: Binding<String>) -> some View {
        SecureField(titre, text: valeur)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .texte(.corps).foregroundStyle(Palette.textePrincipal)
            .padding(.horizontal, 14).frame(height: 46)
            .verreControle(Capsule(), interactif: false)
    }

    private func ligne(fournisseur f: FournisseurModele, total: Int) -> some View {
        HStack(spacing: 12) {
            Pastille(icone: f.type == "api" ? "creditcard" : f.type == "gemini_cli" ? "sparkles" : "person.badge.key",
                     couleur: f.etat == "actif" ? Categorie.ia.couleur : Palette.texteSecondaire)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(f.rang). \(f.libelle)").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Text(etat(f)).texte(.legende)
                    .foregroundStyle(f.etat == "a_reconnecter" ? Categorie.alerte.couleur : Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Menu {
                if f.rang > 1 {
                    Button("Passer devant", systemImage: "arrow.up") { Task { await monter(f) } }
                }
                if f.etat == "coupe" {
                    Button("Reprendre", systemImage: "play") {
                        Task { await modifier("POST", "moi/fournisseurs/\(f.type)/reprendre", nil, "Repris") }
                    }
                } else {
                    Button("Couper", systemImage: "pause") {
                        Task { await modifier("POST", "moi/fournisseurs/\(f.type)/couper", nil, "Coupé") }
                    }
                }
                if f.type == "api" {
                    Button("Plafond à 5 $", systemImage: "dollarsign") { Task { await regler(5) } }
                    Button("Plafond à 10 $", systemImage: "dollarsign") { Task { await regler(10) } }
                    Button("Plafond à 20 $", systemImage: "dollarsign") { Task { await regler(20) } }
                }
                Button("Retirer", systemImage: "trash", role: .destructive) { aRetirer = f }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Palette.texteSecondaire)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Options de \(f.libelle)")
        }
        .padding(Espace.interne)
        .carte(rayon: Rayon.controle)
    }

    private func etat(_ f: FournisseurModele) -> String {
        var morceaux: [String] = []
        switch f.etat {
        case "actif": morceaux.append("Prêt")
        case "de_cote":
            morceaux.append(f.deCoteJusquA.map { "De côté jusqu'à \($0.formatted(.dateTime.hour().minute().locale(enFrancais)))" } ?? "De côté")
        case "a_reconnecter": morceaux.append("Jeton refusé : à recoller")
        case "coupe": morceaux.append("Coupé")
        default: morceaux.append(f.etat)
        }
        if f.type == "api", let modele {
            let plafond = f.plafondMensuel ?? 10
            morceaux.append(String(format: "%.2f $ sur %.0f $ ce mois-ci", modele.depenseApiDuMois, plafond)
                .replacingOccurrences(of: ".", with: ","))
        }
        if let fin = f.secretFin { morceaux.append("…\(fin)") } else if f.type == "api" { morceaux.append("clé du serveur") }
        return morceaux.joined(separator: " · ")
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
                Text(cle.dernierUsage.map { "Utilisée \(quand($0))" } ?? "Jamais utilisée")
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

    private func charger() async {
        guard foyer.connecte else { return }
        do {
            modele = try await foyer.demander("GET", "moi/fournisseurs")
            cles = try await foyer.demander("GET", "moi/cles-mcp")
            sessions = try await foyer.demander("GET", "moi/sessions-mcp")
            erreur = nil
        } catch {
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
