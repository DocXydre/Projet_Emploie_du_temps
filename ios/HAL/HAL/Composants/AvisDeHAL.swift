import SwiftUI

/// Ce que dit HAL : le texte reste blanc pour se lire sur n'importe quelle photo,
/// seule l'étincelle porte la couleur de HAL.
struct AvisDeHAL: View {
    let texte: String
    var style: StyleTexte = .corps
    var secondaire = false

    var body: some View {
        Label {
            Text(texte)
                .texte(style)
                .foregroundStyle(secondaire ? Palette.texteSecondaire : Palette.textePrincipal)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "sparkle").foregroundStyle(Categorie.ia.couleur)
        }
    }
}
