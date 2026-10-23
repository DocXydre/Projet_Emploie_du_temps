import SwiftUI
import WidgetKit

// Ce que partagent les widgets de l'écran d'accueil : l'en-tête, le fond, ce
// qu'ils disent quand ils n'ont rien à montrer.

/// L'icône et le titre en haut du widget, comme dans l'appli.
struct EnTete: View {
    let titre: String
    let icone: String
    let couleur: Color
    var droite: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Label(titre, systemImage: icone).font(.caption.bold()).foregroundStyle(couleur).lineLimit(1)
            if let droite {
                Spacer(minLength: 4)
                Text(droite).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Ce qu'un widget dit quand il n'a rien à montrer (WID-8).
struct RienAMontrer: View {
    let texte: String

    var body: some View {
        Text(texte)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Le fond sombre des widgets HAL, et l'endroit de l'appli qu'ils ouvrent.
    /// L'appli est en sombre : ses widgets aussi, même sur un iPhone réglé en clair.
    func widgetHAL(_ lien: String) -> some View {
        foregroundStyle(.white, .white.opacity(0.6), .white.opacity(0.4))
            .environment(\.colorScheme, .dark)
            .containerBackground(Teinte.fond.gradient, for: .widget)
            .widgetURL(URL(string: lien))
    }
}

/// Le contenu d'un widget sous son en-tête, ou « Ouvre HAL une fois » tant que
/// l'appli n'a rien gardé.
struct Cadre<Contenu: View>: View {
    let entree: Entree
    let titre: String
    let icone: String
    let couleur: Color
    var droite: String? = nil
    @ViewBuilder var contenu: (Instantane) -> Contenu

    var body: some View {
        if let instantane = entree.instantane {
            VStack(alignment: .leading, spacing: 8) {
                EnTete(titre: titre, icone: icone, couleur: couleur, droite: droite)
                contenu(instantane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            PasEncore()
        }
    }
}

/// « 17:42 »
func enHeure(_ date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(francais))
}

/// « mer. 14 oct. »
func enJour(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(francais))
}
