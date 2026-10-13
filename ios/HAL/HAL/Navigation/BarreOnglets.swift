import SwiftUI

/// Les quatre onglets (APP-1). L'orbe de HAL n'en est pas un : il est au centre.
enum Onglet: String, CaseIterable, Identifiable {
    case aujourdhui, sport, maison, reglages

    var id: String { rawValue }

    var libelle: String {
        switch self {
        case .aujourdhui: "Aujourd'hui"
        case .sport: "Sport"
        case .maison: "Maison"
        case .reglages: "Réglages"
        }
    }

    var icone: String {
        switch self {
        case .aujourdhui: "checklist"
        case .sport: "figure.run"
        case .maison: "house"
        case .reglages: "slider.horizontal.3"
        }
    }
}

/// La barre d'onglets en verre, avec l'orbe au milieu. Toucher l'orbe ouvre HAL ;
/// un appui long lance la dictée (ORB-5).
struct BarreOnglets: View {
    @Binding var selection: Onglet
    @Environment(ConversationHAL.self) private var conversation
    @Namespace private var espace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 0) {
                bouton(.aujourdhui)
                bouton(.sport)
                orbe
                bouton(.maison)
                bouton(.reglages)
            }
            .padding(.horizontal, 6)
            .frame(height: 68)
            .verreControle(Capsule(), interactif: false)
        }
        .padding(.horizontal, Espace.marge)
    }

    private func bouton(_ onglet: Onglet) -> some View {
        Button {
            withAnimation(.snappy) { selection = onglet }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: onglet.icone).font(.system(size: 19, weight: .medium))
                Text(onglet.libelle).texte(.onglet).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selection == onglet ? Palette.textePrincipal : Palette.texteSecondaire)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                if selection == onglet {
                    Capsule().fill(Palette.verreTeinteForte).matchedGeometryEffect(id: "onglet", in: espace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(onglet.libelle)
        .accessibilityAddTraits(selection == onglet ? .isSelected : [])
    }

    private var orbe: some View {
        Orbe(etat: conversation.etatOrbe)
            .frame(width: 72, height: 56)
            .contentShape(Circle())
            .onTapGesture {
                if conversation.ouvert { conversation.fermer() } else { conversation.ouvrir() }
            }
            .onLongPressGesture(minimumDuration: 0.4) { conversation.ouvrir(dictee: true) }
            .sensoryFeedback(.impact(weight: .medium), trigger: conversation.ouvert)
            .accessibilityElement()
            .accessibilityLabel("HAL")
            .accessibilityHint(conversation.etatOrbe == .recap ? "HAL a quelque chose à te dire" : "Parler à HAL")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { conversation.ouvert ? conversation.fermer() : conversation.ouvrir() }
    }
}
