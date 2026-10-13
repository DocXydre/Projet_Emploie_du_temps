import SwiftUI

/// Une étiquette : catégorie, statut, « dans 40 min ».
struct Puce: View {
    let texte: String
    var couleur: Color = Palette.textePrincipal
    var fond: Color = Palette.verreTeinteForte

    var body: some View {
        Text(texte)
            .texte(.etiquette)
            .foregroundStyle(couleur)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(fond, in: Capsule())
    }
}

extension Puce {
    init(_ texte: String, categorie: Categorie) {
        self.init(texte: texte, couleur: categorie.couleur, fond: categorie.voile)
    }
}

/// Un anneau de progression : les séances de la semaine, un objectif.
struct Anneau: View {
    /// De 0 à 1.
    let valeur: Double
    var couleur: Color? = nil
    var epaisseur: CGFloat = 6
    var texte: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(Palette.verreTeinteForte, lineWidth: epaisseur)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, valeur)))
                .stroke(couleur ?? theme.principal, style: StrokeStyle(lineWidth: epaisseur, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let texte {
                Text(texte).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            }
        }
        .animation(.smooth, value: valeur)
    }
}

/// L'initiale d'une personne, dans sa couleur.
struct Avatar: View {
    let nom: String
    var couleur: Color = Categorie.travail.couleur
    var taille: CGFloat = 44

    var body: some View {
        Text(nom.prefix(1).uppercased())
            .font(.system(size: taille * 0.42, weight: .semibold))
            .foregroundStyle(Palette.textePrincipal)
            .frame(width: taille, height: taille)
            .background(couleur.opacity(0.35), in: Circle())
            .overlay(Circle().strokeBorder(couleur, lineWidth: 1.5))
            .accessibilityLabel(nom)
    }
}

/// Le petit carré coloré qui porte l'icône d'une ligne de réglage.
struct Pastille: View {
    let icone: String
    let couleur: Color

    var body: some View {
        Image(systemName: icone)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.texteSurAccent)
            .frame(width: 30, height: 30)
            .background(couleur, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Une valeur avec son unité et sa tendance : sommeil, FC de repos, VFC, poids.
/// Une valeur absente s'affiche par un tiret, jamais par 0 (APP-4).
struct Mesure: View {
    let titre: String
    let icone: String
    let valeur: String?
    var unite: String = ""
    var tendance: String? = nil
    var couleur: Color = Categorie.alerte.couleur

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(titre, systemImage: icone)
                .texte(.etiquette)
                .foregroundStyle(Palette.texteSecondaire)
                .labelStyle(EtiquetteIcone(couleur: couleur))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(valeur ?? "—").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                if valeur != nil, !unite.isEmpty {
                    Text(unite).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
            if let tendance {
                Text(tendance).texte(.legende).foregroundStyle(Categorie.sport.couleur)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Espace.interne)
        .carte(rayon: Rayon.controle)
        .accessibilityElement(children: .combine)
    }
}

/// L'icône d'une étiquette de widget, dans la couleur de sa famille.
struct EtiquetteIcone: LabelStyle {
    var couleur: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(couleur).font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// Un en-tête de groupe en capitales : « APPARENCE », « MES HEURES ».
struct EnTeteGroupe: View {
    let texte: String

    var body: some View {
        Text(texte.uppercased())
            .texte(.etiquette)
            .foregroundStyle(Palette.texteSecondaire)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Espace.serre)
            .accessibilityAddTraits(.isHeader)
    }
}
