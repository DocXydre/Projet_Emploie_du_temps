import SwiftUI

/// La photo de fond de toute l'appli, floutée et assombrie pour que le texte
/// reste lisible (THM-1, THM-2). Sans photo choisie, celle de la maquette.
struct Fond: View {
    @Environment(Apparence.self) private var apparence

    var body: some View {
        GeometryReader { geo in
            image
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .saturation(apparence.saturation)
                .blur(radius: apparence.flou * 40, opaque: true)
                .overlay(Color.black.opacity(apparence.assombrissementEffectif))
        }
        .ignoresSafeArea()
        // L'image remplit son cadre en débordant : .clipped() cache ce qui
        // dépasse, mais le débordement reçoit encore les touchers. Dans
        // l'aperçu de « Fond et couleurs », il passait par-dessus le bouton
        // retour. Le fond ne se touche jamais.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var image: Image {
        if let photo = apparence.photo { return Image(uiImage: photo) }
        return Image("FondParDefaut")
    }
}
