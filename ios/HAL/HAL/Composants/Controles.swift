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
    /// Toucher le nombre le fait taper au clavier : une charge de 62,5 kg ne
    /// se règle pas à coups de 0,5.
    var saisie = false
    @Environment(\.theme) private var theme
    @State private var tape = ""
    @State private var enSaisie = false

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
            .contentShape(Rectangle())
            .onTapGesture {
                guard saisie else { return }
                tape = nombre
                enSaisie = true
            }
            bouton("plus") { valeur = min(bornes.upperBound, valeur + pas) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .carte(rayon: Rayon.controle)
        .animation(.snappy, value: valeur)
        .alert(titre.prefix(1).uppercased() + titre.dropFirst(), isPresented: $enSaisie) {
            TextField(nombre, text: $tape)
                .keyboardType(pas.truncatingRemainder(dividingBy: 1) == 0 ? .numberPad : .decimalPad)
            Button("OK") { poser(tape) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(unite.isEmpty ? "Au pas de \(texte(pas))." : "En \(unite), au pas de \(texte(pas)).")
        }
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

    private var nombre: String { texte(valeur) }

    private func texte(_ x: Double) -> String {
        x.formatted(.number.precision(.fractionLength(0...1))
            .grouping(.never).locale(Locale(identifier: "fr_FR")))
    }

    /// « 62,5 » ou « 62.5 », ramené au pas et dans les bornes.
    private func poser(_ saisi: String) {
        let propre = saisi.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }
        guard let lu = Double(propre) else { return }
        let arrondi = (lu / pas).rounded() * pas
        valeur = min(bornes.upperBound, max(bornes.lowerBound, arrondi))
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
        // Rester appuyé fait défiler : de 40 à 60 kg sans quarante appuis.
        .buttonRepeatBehavior(.enabled)
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

/// Les deux couleurs d'un duo, moitié-moitié dans un rond.
struct RondDuo: View {
    let principal: Color
    let secondaire: Color
    var taille: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(principal)
            Rectangle().fill(secondaire)
        }
        .frame(width: taille, height: taille)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Palette.verreBord, lineWidth: 0.5))
    }
}

/// Le dépliant des duos (THM-3) : le duo en vigueur, qui s'ouvre sur les autres.
struct DepliantDuos: View {
    @Environment(Apparence.self) private var apparence
    @State private var deplie = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth) { deplie.toggle() }
            } label: {
                HStack(spacing: 12) {
                    RondDuo(principal: apparence.theme.principal, secondaire: apparence.theme.secondaire, taille: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couleur de l'appli").texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Text(apparence.couleursDeLaPhoto ? "Tirée de la photo" : apparence.combinaison.nom)
                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.texteSecondaire)
                        .rotationEffect(.degrees(deplie ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(apparence.couleursDeLaPhoto ? "Tirée de la photo" : apparence.combinaison.nom)

            if deplie {
                VStack(spacing: 0) {
                    ForEach(Combinaison.allCases) { combinaison in
                        let choisie = !apparence.couleursDeLaPhoto && apparence.combinaison == combinaison
                        Button {
                            withAnimation(.smooth) {
                                apparence.couleursDeLaPhoto = false
                                apparence.combinaison = combinaison
                                deplie = false
                            }
                        } label: {
                            HStack(spacing: 12) {
                                RondDuo(principal: combinaison.principal, secondaire: combinaison.secondaire)
                                Text(combinaison.nom).texte(.corps)
                                    .foregroundStyle(choisie ? Palette.textePrincipal : Palette.texteSecondaire)
                                Spacer(minLength: 0)
                                if choisie {
                                    Image(systemName: "checkmark").foregroundStyle(combinaison.principal)
                                }
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(choisie ? .isSelected : [])
                    }
                    Text("L'icône de l'appli prend la même couleur.")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
