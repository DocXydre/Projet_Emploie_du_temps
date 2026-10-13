import SwiftUI

/// La galerie des modules : on en choisit un, sa taille, on voit l'aperçu et on
/// l'ajoute (WID-3). Un module inscrit au registre y apparaît tout seul.
struct Galerie: View {
    @Environment(Disposition.self) private var disposition
    @Environment(\.dismiss) private var fermer
    @State private var choisi: Module.ID?
    @State private var taille: TailleWidget = .moyen

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Espace.gouttiere) {
                    BarreDeTitre(titre: "Ajouter un widget") {
                        BoutonRond("xmark", libelle: "Fermer") { fermer() }
                    }
                    if disposition.disponibles.isEmpty {
                        Text("Tous les widgets sont déjà sur l'accueil.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(disposition.disponibles) { module in
                        ligne(module)
                    }
                }
                .padding(.horizontal, Espace.marge)
                .padding(.bottom, 40)
            }
            // La feuille d'iOS reste en Liquid Glass : l'accueil se voit dessous.
            .ecranHAL()
        }
    }

    @ViewBuilder
    private func ligne(_ module: Module) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) {
                    choisi = choisi == module.id ? nil : module.id
                    taille = module.tailleParDefaut
                }
            } label: {
                HStack(spacing: 12) {
                    Pastille(icone: module.icone, couleur: module.categorie.couleur)
                    Text(module.nom).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    Image(systemName: choisi == module.id ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Palette.texteTertiaire)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if choisi == module.id {
                if module.tailles.count > 1 {
                    Segmente(choix: module.tailles.map { ($0, $0.libelle) }, selection: $taille)
                }
                HStack {
                    module.widget(taille)
                        .aspectRatio(taille == .moyen ? 2.07 : 1, contentMode: .fit)
                        .frame(maxWidth: taille == .petit ? 180 : .infinity)
                        .allowsHitTesting(false)
                    if taille == .petit { Spacer() }
                }
                Button("Ajouter à l'accueil") {
                    disposition.ajouter(module, taille: taille)
                    fermer()
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
            }
        }
        .padding(Espace.interne)
        .carte(rayon: Rayon.controle)
    }
}
