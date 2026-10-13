import SwiftUI

/// Les styles du bouton de la maquette.
enum StyleBouton {
    /// Plein, dans la couleur principale : l'action attendue.
    case accent
    /// En verre : une action secondaire.
    case verre
    /// En verre teinté de la couleur principale.
    case verreAccent
    /// Pour ce qui retire ou annule.
    case danger
}

/// Le bouton de l'appli : `Button("Lancer") { … }.buttonStyle(.hal(.accent))`.
struct StyleBoutonHAL: ButtonStyle {
    let style: StyleBouton
    var pleineLargeur = false
    var grand = false
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var actif

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .texte(.corpsFort)
            .lineLimit(1)
            .foregroundStyle(couleurTexte)
            .padding(.horizontal, 16)
            .frame(maxWidth: pleineLargeur ? .infinity : nil)
            .frame(height: grand ? 54 : 36)
            .contentShape(Capsule())
            .verreControle(Capsule(), teinte: teinte)
            .opacity(actif ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }

    private var teinte: Color? {
        switch style {
        case .accent: theme.principal
        case .verre: nil
        case .verreAccent: theme.principalVoile
        case .danger: Categorie.alerte.voile
        }
    }

    private var couleurTexte: Color {
        switch style {
        case .accent: theme.surPrincipal
        case .verre: Palette.textePrincipal
        case .verreAccent: theme.principal
        case .danger: Categorie.alerte.couleur
        }
    }
}

extension ButtonStyle where Self == StyleBoutonHAL {
    static func hal(_ style: StyleBouton, pleineLargeur: Bool = false, grand: Bool = false) -> StyleBoutonHAL {
        StyleBoutonHAL(style: style, pleineLargeur: pleineLargeur, grand: grand)
    }
}

/// Le bouton rond des en-têtes : « + », crayon, fermer, retour.
struct BoutonRond: View {
    let icone: String
    var libelle: String
    var action: () -> Void

    init(_ icone: String, libelle: String, action: @escaping () -> Void) {
        self.icone = icone
        self.libelle = libelle
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icone)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textePrincipal)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .verreControle(Circle())
        .accessibilityLabel(libelle)
    }
}
