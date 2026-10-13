import SwiftUI

/// Les rayons et les espacements de la maquette (collection « Tokens »).
enum Rayon {
    static let widget: CGFloat = 28
    static let controle: CGFloat = 18
    static let ligne: CGFloat = 14
}

enum Espace {
    /// La marge de chaque côté de l'écran.
    static let marge: CGFloat = 16
    /// L'écart entre deux widgets.
    static let gouttiere: CGFloat = 12
    /// Le retrait du contenu dans un widget.
    static let interne: CGFloat = 16
    static let serre: CGFloat = 8
    static let mini: CGFloat = 4
}

/// Les styles de texte de la maquette. SF Pro dans l'appli, Inter dans Figma :
/// tailles, graisses et interlignes sont les mêmes.
enum StyleTexte {
    case grandTitre, titre, titreWidget, corps, corpsFort, legende, etiquette, chiffre, onglet

    var taille: CGFloat {
        switch self {
        case .grandTitre: 34
        case .titre: 22
        case .titreWidget: 17
        case .corps, .corpsFort: 15
        case .legende: 13
        case .etiquette: 12
        case .chiffre: 28
        case .onglet: 10
        }
    }

    var graisse: Font.Weight {
        switch self {
        case .grandTitre, .titre, .chiffre: .bold
        case .titreWidget, .corpsFort, .etiquette: .semibold
        case .onglet: .medium
        case .corps, .legende: .regular
        }
    }

    /// La hauteur de ligne de la maquette, en points.
    var hauteurLigne: CGFloat {
        switch self {
        case .grandTitre: 41
        case .titre: 28
        case .titreWidget: 22
        case .corps, .corpsFort: 20
        case .legende: 18
        case .etiquette: 16
        case .chiffre: 32
        case .onglet: 12
        }
    }

    var approche: CGFloat {
        switch self {
        case .grandTitre: 0.4
        case .titre: -0.26
        case .titreWidget: -0.43
        case .corps, .corpsFort: -0.23
        case .legende: -0.08
        case .onglet: 0.1
        case .etiquette, .chiffre: 0
        }
    }

    /// Le style système dont la taille suit le réglage de taille du texte d'iOS.
    var relatif: Font.TextStyle {
        switch self {
        case .grandTitre: .largeTitle
        case .titre: .title2
        case .titreWidget: .headline
        case .corps, .corpsFort: .subheadline
        case .legende: .footnote
        case .etiquette: .caption
        case .chiffre: .title
        case .onglet: .caption2
        }
    }

    /// Les chiffres gardent la même largeur, pour que les heures s'alignent.
    var chiffresFixes: Bool { self == .chiffre }
}

private struct ModificateurTexte: ViewModifier {
    let style: StyleTexte
    @ScaledMetric private var taille: CGFloat
    @ScaledMetric private var ligne: CGFloat

    init(style: StyleTexte) {
        self.style = style
        _taille = ScaledMetric(wrappedValue: style.taille, relativeTo: style.relatif)
        _ligne = ScaledMetric(wrappedValue: style.hauteurLigne, relativeTo: style.relatif)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: taille, weight: style.graisse))
            .monospacedDigit()
            .tracking(style.approche)
            .lineSpacing(max(0, ligne - taille * 1.2))
    }
}

extension View {
    /// Applique un style de texte de la maquette : `Text("…").texte(.corps)`.
    func texte(_ style: StyleTexte) -> some View {
        modifier(ModificateurTexte(style: style))
    }
}
