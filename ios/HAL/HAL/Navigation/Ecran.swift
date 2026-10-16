import SwiftUI

extension View {
    /// Ce que chaque écran met autour de son contenu : un fond transparent, pour
    /// laisser voir la photo de la racine, et pas de barre de navigation système.
    /// Les écrans dessinent leur propre en-tête.
    func ecranHAL() -> some View {
        self
            .toolbarVisibility(.hidden, for: .navigationBar)
            .containerBackground(.clear, for: .navigation)
    }
}

/// La barre d'onglets flotte au-dessus des écrans : le bas d'une page qui
/// défile doit pouvoir passer au-dessus d'elle.
private struct MargeDeLaBarre: ViewModifier {
    @Environment(\.margeBasse) private var margeBasse

    func body(content: Content) -> some View {
        content.contentMargins(.bottom, margeBasse, for: .scrollContent)
    }
}

extension View {
    func margeDeLaBarre() -> some View { modifier(MargeDeLaBarre()) }
}

/// Un écran qui défile, avec les marges de la maquette.
struct PageDefilante<Contenu: View>: View {
    @ViewBuilder var contenu: Contenu
    @Environment(\.margeBasse) private var margeBasse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                contenu
            }
            .padding(.horizontal, Espace.marge)
            .padding(.top, Espace.serre)
            .padding(.bottom, Espace.marge + margeBasse)
            .animation(.smooth(duration: 0.35), value: margeBasse)
        }
        .scrollIndicators(.hidden)
        .ecranHAL()
    }
}

/// Un écran poussé : la barre de titre avec retour, puis le contenu qui défile.
struct PagePoussee<Contenu: View>: View {
    let titre: String
    @ViewBuilder var contenu: Contenu
    @Environment(\.dismiss) private var fermer

    var body: some View {
        PageDefilante {
            BarreDeTitre(titre: titre, retour: { fermer() })
            contenu
        }
    }
}
