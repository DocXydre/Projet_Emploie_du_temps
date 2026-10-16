import SwiftUI

/// Un compteur à gros boutons, pour la charge et les répétitions pendant la
/// séance (3.5) : le nombre en grand, son unité dessous, « − » et « + » en verre.
struct Compteur: View {
    let titre: String
    @Binding var valeur: Double
    var pas: Double = 1
    var bornes: ClosedRange<Double> = 0...999
    var unite: String = ""
    /// Des boutons plus petits, pour tenir à côté d'un libellé (3.9).
    var compact = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: compact ? 6 : 12) {
            bouton("minus") { valeur = max(bornes.lowerBound, valeur - pas) }
            VStack(spacing: 0) {
                Text(nombre)
                    .font(.system(size: compact ? 30 : 38, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.textePrincipal)
                    .contentTransition(.numericText(value: valeur))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unite.isEmpty ? titre.lowercased() : unite)
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            .frame(maxWidth: .infinity)
            bouton("plus") { valeur = min(bornes.upperBound, valeur + pas) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .carte(rayon: Rayon.controle)
        .animation(.snappy, value: valeur)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(titre)
        .accessibilityValue(enClair)
        .accessibilityAdjustableAction { sens in
            switch sens {
            case .increment: valeur = min(bornes.upperBound, valeur + pas)
            case .decrement: valeur = max(bornes.lowerBound, valeur - pas)
            @unknown default: break
            }
        }
    }

    private var nombre: String {
        valeur.formatted(.number.precision(.fractionLength(0...1))
            .grouping(.never).locale(Locale(identifier: "fr_FR")))
    }

    private var enClair: String {
        unite.isEmpty ? nombre : "\(nombre) \(unite)"
    }

    private func bouton(_ icone: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icone)
                .font(.system(size: compact ? 16 : 20, weight: .semibold))
                .foregroundStyle(Palette.textePrincipal)
                .frame(width: compact ? 40 : 52, height: compact ? 40 : 52)
        }
        .buttonStyle(.plain)
        .verreControle(Circle())
        .sensoryFeedback(.selection, trigger: valeur)
    }
}

/// Deux à quatre choix côte à côte : 7, 30 ou 90 jours ; Petit, Moyen, Grand.
struct Segmente<Valeur: Hashable>: View {
    let choix: [(Valeur, String)]
    @Binding var selection: Valeur
    @Namespace private var espace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(choix.indices, id: \.self) { rang in
                let valeur = choix[rang].0
                let libelle = choix[rang].1
                Button {
                    withAnimation(.snappy) { selection = valeur }
                } label: {
                    Text(libelle)
                        .texte(.corpsFort)
                        .foregroundStyle(selection == valeur ? Palette.textePrincipal : Palette.texteSecondaire)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if selection == valeur {
                                Capsule().fill(Palette.verreTeinteForte)
                                    .matchedGeometryEffect(id: "selection", in: espace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == valeur ? .isSelected : [])
            }
        }
        .padding(4)
        .verreControle(Capsule(), interactif: false)
    }
}

/// Le haut d'un écran poussé : retour, titre, et un bouton à droite si besoin.
struct BarreDeTitre<Droite: View>: View {
    let titre: String
    var sousTitre: String? = nil
    var retour: (() -> Void)? = nil
    @ViewBuilder var droite: Droite

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Text(titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                if let sousTitre {
                    Text(sousTitre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
            .surLaPhoto()
            HStack {
                if let retour { BoutonRond("chevron.left", libelle: "Retour", action: retour) }
                Spacer()
                droite
            }
        }
        .frame(height: 44)
    }
}

extension BarreDeTitre where Droite == EmptyView {
    init(titre: String, sousTitre: String? = nil, retour: (() -> Void)? = nil) {
        self.init(titre: titre, sousTitre: sousTitre, retour: retour) { EmptyView() }
    }
}

/// Le grand en-tête d'un onglet : la date ou le contexte, puis le titre.
struct EnTeteOnglet<Boutons: View>: View {
    let surTitre: String
    let titre: String
    @ViewBuilder var boutons: Boutons

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text(surTitre.uppercased()).texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                Text(titre).texte(.grandTitre).foregroundStyle(Palette.textePrincipal)
                    .accessibilityAddTraits(.isHeader)
            }
            .surLaPhoto()
            Spacer()
            HStack(spacing: 8) { boutons }
        }
    }
}

/// Une des quatre combinaisons, à toucher pour la choisir.
struct PastilleTheme: View {
    let combinaison: Combinaison
    let choisie: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    Rectangle().fill(combinaison.principal)
                    Rectangle().fill(combinaison.secondaire)
                }
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .overlay {
                    if choisie {
                        Circle().strokeBorder(Palette.textePrincipal, lineWidth: 2).padding(-4)
                    }
                }
                .padding(4)
                Text(combinaison.nom.replacingOccurrences(of: " · ", with: "\n"))
                    .texte(.legende)
                    .foregroundStyle(choisie ? Palette.textePrincipal : Palette.texteSecondaire)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(combinaison.nom)
        .accessibilityAddTraits(choisie ? .isSelected : [])
    }
}
