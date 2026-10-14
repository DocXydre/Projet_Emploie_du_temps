import SwiftUI

/// Les trois styles de verre de la maquette (THM-5).
/// Le verre sert à ce qui flotte ; les cartes suivent le réglage de l'appareil :
/// Liquid Glass, transparent ou dépoli.
extension View {
    /// La carte d'un widget ou d'un groupe de réglages.
    func carte(rayon: CGFloat = Rayon.widget) -> some View {
        modifier(Carte(rayon: rayon))
    }

    /// Du texte posé à même la photo, sans carte : titres d'écran et de groupe.
    /// Une ombre douce le détache d'une photo claire.
    func surLaPhoto() -> some View {
        shadow(color: .black.opacity(0.45), radius: 6, y: 1)
    }

    /// Un contrôle qui flotte : bouton, barre, champ.
    func verreControle<Forme: Shape>(_ forme: Forme, teinte: Color? = nil, interactif: Bool = true) -> some View {
        var verre = Glass.regular
        if let teinte { verre = verre.tint(teinte) }
        if interactif { verre = verre.interactive() }
        return glassEffect(verre, in: forme)
    }
}

extension ReglageVerre {
    /// Le verre d'iOS qui correspond au réglage, ou rien pour le verre dépoli.
    var glass: Glass? {
        let sombre = Color.black.opacity(teinte)
        switch style {
        case .liquide: return Glass.regular.tint(sombre)
        case .liquideClair: return Glass.clear.tint(sombre)
        case .depoli: return nil
        }
    }
}

/// Une carte : du Liquid Glass, ou le flou dépoli d'avant, selon Réglages.
private struct Carte: ViewModifier {
    let rayon: CGFloat
    @Environment(\.verre) private var verre

    func body(content: Content) -> some View {
        let forme = RoundedRectangle(cornerRadius: rayon, style: .continuous)
        if let glass = verre.glass {
            content.glassEffect(glass, in: forme)
        } else {
            content
                .background(.ultraThinMaterial, in: forme)
                .background(Palette.verreTeinte, in: forme)
                .overlay(forme.strokeBorder(Palette.verreBord, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        }
    }
}
