import SwiftUI
import UIKit

// Réglages, Intelligence (FOU-19, partie F) : les clients MCP qui lisent HAL
// depuis un ordinateur, leurs clés et leurs dernières sessions. Les
// fournisseurs du modèle (abonnement, API) s'y ajouteront au lot 13.

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

/// Intelligence : brancher Claude Code ou un autre client MCP sur HAL.
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

    private struct NouvelleCle: Encodable { let nom: String }

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
                Button("Copier la configuration Gemini CLI") { copier(gemini, "Configuration copiée") }
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
