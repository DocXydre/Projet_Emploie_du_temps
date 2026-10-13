import SwiftUI

/// Une rangée de l'accueil : un widget en pleine largeur, ou deux petits côte à côte.
private enum Rangee: Identifiable {
    case pleine(Place)
    case double(Place?, Place?)

    var id: String {
        switch self {
        case .pleine(let place): place.id.uuidString
        case .double(let gauche, let droite): (gauche?.id.uuidString ?? "vide") + (droite?.id.uuidString ?? "vide")
        }
    }
}

/// La grille de widgets d'Aujourd'hui, avec son mode édition (WID-3, WID-7).
struct TableauDeBord: View {
    @Binding var edition: Bool
    var ouvrir: (Module) -> Void
    var ajouter: () -> Void
    @Environment(Disposition.self) private var disposition

    /// La séance libre ferme toujours la grille, en bas à droite (WID-7).
    private static let placeSeanceLibre = Place(id: UUID(uuidString: "00000000-0000-0000-0000-00000000501E")!,
                                                module: Module.seanceLibre.id, taille: .petit)

    var body: some View {
        VStack(spacing: Espace.gouttiere) {
            ForEach(rangees) { rangee in
                switch rangee {
                case .pleine(let place):
                    cellule(place)
                case .double(let gauche, let droite):
                    HStack(spacing: Espace.gouttiere) {
                        if let gauche { cellule(gauche) } else { caseAjouter }
                        if let droite { cellule(droite) } else { Color.clear.aspectRatio(1, contentMode: .fit) }
                    }
                }
            }
        }
    }

    private var rangees: [Rangee] {
        var resultat: [Rangee] = []
        var enAttente: Place?
        for place in disposition.places {
            if place.taille == .petit {
                if let gauche = enAttente {
                    resultat.append(.double(gauche, place))
                    enAttente = nil
                } else {
                    enAttente = place
                }
            } else {
                if let gauche = enAttente {
                    resultat.append(.double(gauche, nil))
                    enAttente = nil
                }
                resultat.append(.pleine(place))
            }
        }
        resultat.append(.double(enAttente, Self.placeSeanceLibre))
        return resultat
    }

    @ViewBuilder
    private func cellule(_ place: Place) -> some View {
        if let module = Registre.module(place.module) {
            CelluleWidget(module: module, place: place, edition: edition,
                          ouvrir: { ouvrir(module) },
                          retirer: { withAnimation(.snappy) { disposition.retirer(place) } },
                          redimensionner: { withAnimation(.snappy) { disposition.changerTaille(place) } })
                .modifier(Glisser(place: place, actif: edition && !module.fixe))
        }
    }

    /// La case libre à gauche de la séance libre : elle ouvre la galerie.
    private var caseAjouter: some View {
        Button(action: ajouter) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                Text("Ajouter un widget").texte(.legende)
            }
            .foregroundStyle(Palette.texteSecondaire)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Rayon.widget, style: .continuous)
                    .strokeBorder(Palette.verreBord, style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
            }
        }
        .buttonStyle(.plain)
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Un widget dans la grille, à sa taille, avec ses poignées en mode édition.
struct CelluleWidget: View {
    let module: Module
    let place: Place
    let edition: Bool
    var ouvrir: () -> Void
    var retirer: () -> Void
    var redimensionner: () -> Void
    @State private var tremble = false

    var body: some View {
        module.widget(place.taille)
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: Rayon.widget))
            .onTapGesture { if !edition { ouvrir() } }
            .allowsHitTesting(true)
            .overlay(alignment: .topLeading) {
                if edition && !module.fixe {
                    poignee("minus", libelle: "Retirer \(module.nom)", action: retirer)
                        .offset(x: -6, y: -6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if edition && module.tailles.count > 1 {
                    poignee("arrow.up.left.and.arrow.down.right", libelle: "Changer la taille de \(module.nom)",
                            action: redimensionner)
                        .offset(x: 6, y: 6)
                }
            }
            .rotationEffect(.degrees(edition && !module.fixe ? (tremble ? 0.8 : -0.8) : 0))
            .onChange(of: edition) { lancerTremblement() }
            .onAppear(perform: lancerTremblement)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Ouvrir") { ouvrir() }
    }

    /// Petit : un carré. Moyen : la largeur de deux petits sur la hauteur d'un. Grand : un carré plein.
    private var ratio: CGFloat {
        switch place.taille {
        case .petit: 1
        case .moyen: 2.07
        case .grand: 1
        }
    }

    private func lancerTremblement() {
        guard edition else { tremble = false; return }
        withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { tremble.toggle() }
    }

    private func poignee(_ icone: String, libelle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icone)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.textePrincipal)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .verreControle(Circle())
        .accessibilityLabel(libelle)
    }
}

/// Le glisser-déposer pour réordonner les widgets en mode édition.
private struct Glisser: ViewModifier {
    let place: Place
    let actif: Bool
    @Environment(Disposition.self) private var disposition

    @ViewBuilder
    func body(content: Content) -> some View {
        if actif {
            content
                .draggable(place.id.uuidString)
                .dropDestination(for: String.self) { recus, _ in
                    guard let texte = recus.first, let id = UUID(uuidString: texte) else { return false }
                    withAnimation(.snappy) { disposition.deplacer(id, avant: place) }
                    return true
                }
        } else {
            content
        }
    }
}

/// Un bandeau d'état en haut d'Aujourd'hui : hors réseau, mode allégé, absence, pause (WID-6).
struct BandeauEtat: View {
    let icone: String
    let titre: String
    let detail: String
    let categorie: Categorie
    var bouton: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icone).foregroundStyle(categorie.couleur).font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            Spacer(minLength: 8)
            if let bouton {
                Button(bouton, action: action).buttonStyle(.hal(.verre))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(categorie.voile, in: RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous)
            .strokeBorder(Palette.verreBord, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
