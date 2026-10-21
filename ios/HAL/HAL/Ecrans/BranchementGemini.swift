import SwiftUI
import UIKit

// Brancher Gemini (FOU-17, FOU-18) : la carte de Réglages, Intelligence qui dit
// pas à pas quoi coller. Deux façons : le compte Google, qui fait travailler son
// abonnement Google AI (ou le quota gratuit), ou une clé de l'API Gemini.

struct CarteGemini: View {
    @Binding var texte: String
    /// Gemini CLI est dans l'image du serveur.
    let installe: Bool
    /// Les identifiants gardés ont été refusés : il faut les recoller.
    let aRecoller: Bool
    let envoi: Bool
    let brancher: () -> Void
    let copier: (String, String) -> Void

    @Environment(\.openURL) private var ouvrir
    @State private var facon: Facon = .google

    enum Facon: String, CaseIterable, Identifiable {
        case google = "Compte Google"
        case cle = "Clé d'API"
        var id: String { rawValue }
    }

    private static let installer = "npm install -g @google/gemini-cli"
    private static let copierFichier = "cat ~/.gemini/oauth_creds.json | pbcopy"
    private static let pageDesCles = URL(string: "https://aistudio.google.com/apikey")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Pastille(icone: "sparkles", couleur: Categorie.ia.couleur)
                Text("Gemini").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            }
            if aRecoller {
                Text("Google a refusé les identifiants gardés : refais les étapes et recolle-les.")
                    .texte(.legende).foregroundStyle(Categorie.alerte.couleur)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !installe {
                Text("Gemini CLI n'est pas installé sur le serveur : son image a été construite avec GEMINI_CLI=0.")
                    .texte(.legende).foregroundStyle(Categorie.alerte.couleur)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Façon de se connecter", selection: $facon) {
                ForEach(Facon.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch facon {
            case .google:
                etape(1, "Sur ton ordinateur, installe Gemini CLI (il lui faut Node.js) :",
                      commande: Self.installer)
                etape(2, "Lance `gemini`, choisis « Sign in with Google » et valide dans le navigateur.")
                etape(3, "Copie le fichier de connexion :",
                      commande: Self.copierFichier)
                etape(4, "Colle-le ci-dessous, en entier : il commence par { et contient « refresh_token ».")
            case .cle:
                etape(1, "Crée une clé sur Google AI Studio, avec ton compte Google.")
                Button("Ouvrir Google AI Studio") { ouvrir(Self.pageDesCles) }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                etape(2, "Colle-la ci-dessous : elle commence par AIza.")
            }

            TextField(facon == .google ? "{\"access_token\": …, \"refresh_token\": …}" : "AIza…",
                      text: $texte, axis: .vertical)
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Palette.textePrincipal)
                .padding(12)
                .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 10) {
                Button("Coller") {
                    if let colle = UIPasteboard.general.string { texte = colle }
                }
                .buttonStyle(.hal(.verre, pleineLargeur: true))
                if !texte.isEmpty {
                    Button("Effacer") { texte = "" }
                        .buttonStyle(.hal(.verre, pleineLargeur: true))
                }
            }
            if let avis = avis {
                Label(avis.texte, systemImage: avis.bon ? "checkmark.circle" : "exclamationmark.circle")
                    .texte(.legende)
                    .foregroundStyle(avis.bon ? Categorie.sport.couleur : Categorie.alerte.couleur)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Brancher Gemini", action: brancher)
                .buttonStyle(.hal(.accent, pleineLargeur: true))
                .disabled(!(avis?.bon ?? false) || envoi || !installe)
        }
        .padding(Espace.interne)
        .carte(rayon: Rayon.controle)
    }

    /// Ce que le texte collé a l'air d'être, avant même de l'envoyer.
    private var avis: (texte: String, bon: Bool)? {
        let propre = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        if propre.isEmpty { return nil }
        if propre.hasPrefix("{") {
            guard propre.hasSuffix("}") else {
                return ("Le fichier semble coupé : copie-le en entier, jusqu'à la dernière }.", false)
            }
            return propre.contains("\"refresh_token\"")
                ? ("Fichier de connexion Google reconnu.", true)
                : ("Il manque « refresh_token » : reconnecte-toi avec `gemini`, puis recopie le fichier.", false)
        }
        if propre.hasPrefix("AIza") {
            return propre.count >= 39 && !propre.contains(" ")
                ? ("Clé de l'API Gemini reconnue.", true)
                : ("Cette clé semble incomplète.", false)
        }
        if propre.hasPrefix("sk-ant-") {
            return ("C'est un jeton Claude : il va dans la carte de l'abonnement Claude.", false)
        }
        return ("Ce n'est ni le fichier de connexion Google ni une clé Gemini.", false)
    }

    @ViewBuilder
    private func etape(_ numero: Int, _ consigne: String, commande: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(numero).").texte(.corpsFort).foregroundStyle(Categorie.ia.couleur)
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(consigne))
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
                if let commande {
                    HStack(spacing: 8) {
                        Text(commande)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Palette.textePrincipal)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            copier(commande, "Commande copiée")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel("Copier la commande")
                    }
                    .padding(10)
                    .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}
