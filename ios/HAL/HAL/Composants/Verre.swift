import SwiftUI

/// Les trois styles de verre de la maquette (THM-5).
/// Le verre sert à ce qui flotte ; les widgets sont des cartes plus opaques.
extension View {
    /// La carte d'un widget ou d'un groupe de réglages.
    func carte(rayon: CGFloat = Rayon.widget) -> some View {
        let forme = RoundedRectangle(cornerRadius: rayon, style: .continuous)
        return background(.ultraThinMaterial, in: forme)
            .background(Palette.verreTeinte, in: forme)
            .overlay(forme.strokeBorder(Palette.verreBord, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    /// Un contrôle qui flotte : bouton, barre, champ.
    func verreControle<Forme: Shape>(_ forme: Forme, teinte: Color? = nil, interactif: Bool = true) -> some View {
        var verre = Glass.regular
        if let teinte { verre = verre.tint(teinte) }
        if interactif { verre = verre.interactive() }
        return glassEffect(verre, in: forme)
    }
}
