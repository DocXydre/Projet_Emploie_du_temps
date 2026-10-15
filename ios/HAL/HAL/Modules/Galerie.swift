import SwiftUI

/// 1.10 : la galerie des modules. La taille en haut, l'aperçu du module choisi,
/// « Ajouter le widget », puis tous les modules à choisir (WID-3). Un module
/// inscrit au registre y apparaît tout seul.
struct Galerie: View {
    @Environment(Disposition.self) private var disposition
    @Environment(\.dismiss) private var fermer
    @State private var choisi: Module.ID?
    @State private var taille: TailleWidget = .moyen

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Espace.gouttiere) {
                    HStack {
                        Text("Ajouter un widget").texte(.titre).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        BoutonRond("xmark", libelle: "Fermer") { fermer() }
                    }
                    .padding(.top, Espace.serre)
                    if let module {
                        apercu(module)
                    } else {
                        Text("Tous les widgets sont déjà sur l'accueil.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if !disposition.disponibles.isEmpty {
                        EnTeteGroupe(texte: "Tous les modules")
                        GroupeReglages {
                            ForEach(disposition.disponibles) { candidat in
                                Button {
                                    withAnimation(.snappy) {
                                        choisi = candidat.id
                                        taille = candidat.tailleParDefaut
                                    }
                                } label: {
                                    LigneReglage(icone: candidat.icone, couleur: candidat.categorie.couleur,
                                                 libelle: candidat.nom,
                                                 accessoire: candidat.id == module?.id ? .valeur("choisi") : .chevron(),
                                                 sousTitre: candidat.tailles.map(\.libelle).joined(separator: ", "))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, Espace.marge)
                .padding(.bottom, 40)
            }
            // La feuille d'iOS reste en Liquid Glass : l'accueil se voit dessous.
            .ecranHAL()
        }
        .onAppear {
            if choisi == nil, let premier = disposition.disponibles.first {
                choisi = premier.id
                taille = premier.tailleParDefaut
            }
        }
    }

    /// Le module choisi, ou le premier disponible.
    private var module: Module? {
        disposition.disponibles.first { $0.id == choisi } ?? disposition.disponibles.first
    }

    private func apercu(_ module: Module) -> some View {
        VStack(spacing: Espace.gouttiere) {
            if module.tailles.count > 1 {
                Segmente(choix: module.tailles.map { ($0, $0.libelle) }, selection: $taille)
            }
            module.widget(taille)
                .aspectRatio(taille == .moyen ? 2.07 : 1, contentMode: .fit)
                .frame(maxWidth: taille == .petit ? 180 : .infinity)
                .allowsHitTesting(false)
                .id("\(module.id)-\(taille.rawValue)")
            Text(module.nom).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            Button("Ajouter le widget") {
                disposition.ajouter(module, taille: taille)
                fermer()
            }
            .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
        }
        .frame(maxWidth: .infinity)
    }
}
