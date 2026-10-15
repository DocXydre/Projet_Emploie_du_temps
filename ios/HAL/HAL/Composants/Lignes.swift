import SwiftUI

/// Une ligne du planning : la pastille de la famille, l'heure, le titre, le lieu.
struct LigneEvenement: View {
    let heure: String
    let titre: String
    var lieu: String? = nil
    let categorie: Categorie
    var passe = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(categorie.couleur).frame(width: 7, height: 7)
            Text(heure)
                .texte(.corpsFort)
                .foregroundStyle(Palette.textePrincipal)
                .frame(width: 46, alignment: .leading)
            Text(lieu.map { "\(titre) · \($0)" } ?? titre)
                .texte(.corps)
                .foregroundStyle(Palette.texteSecondaire)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .opacity(passe ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// Une tâche à cocher. Cocher celle de l'autre la crédite à qui l'a faite (EXE-14).
struct LigneTache: View {
    let titre: String
    var pourQui: String? = nil
    let faite: Bool
    /// À droite : l'heure, ou le retard en rouge (4.1).
    var detail: String? = nil
    var detailEnAlerte = false
    /// L'initiale et la couleur de la personne, tout à droite (4.1).
    var avatar: (nom: String, couleur: Color)? = nil
    /// APP-10 : cochée mais pas encore envoyée. Jusqu'à cette heure, toucher la
    /// tâche la décoche ; la ligne le dit à la place du détail.
    var annulableJusqua: Date? = nil
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(faite ? theme.principal : Palette.texteSecondaire, lineWidth: 1.5)
                    if faite {
                        Circle().fill(theme.principal)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.surPrincipal)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(titre)
                        .texte(.corps)
                        .foregroundStyle(faite ? Palette.texteTertiaire : Palette.textePrincipal)
                        .lineLimit(1)
                    if let pourQui {
                        Text(pourQui).texte(.legende).foregroundStyle(Palette.texteTertiaire)
                    }
                }
                Spacer(minLength: 0)
                if let annulableJusqua, annulableJusqua > .now {
                    TimelineView(.periodic(from: .now, by: 1)) { contexte in
                        let reste = Int(annulableJusqua.timeIntervalSince(contexte.date).rounded(.up))
                        if reste > 0 {
                            Label("décocher · \(reste) s", systemImage: "arrow.uturn.backward")
                                .labelStyle(.titleAndIcon)
                                .texte(.legende).foregroundStyle(theme.principal)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                } else if let detail {
                    Text(detail).texte(.legende)
                        .foregroundStyle(detailEnAlerte ? Categorie.alerte.couleur : Palette.texteSecondaire)
                        .lineLimit(1)
                }
                if let avatar {
                    Avatar(nom: avatar.nom, couleur: avatar.couleur, taille: 26)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: faite) { _, maintenant in maintenant }
        .accessibilityLabel(titre)
        .accessibilityValue(faite ? (annulableJusqua != nil ? "faite, touche pour décocher" : "faite") : "à faire")
    }
}

/// Ce qui se trouve à droite d'une ligne de réglage.
enum AccessoireReglage {
    case chevron(String? = nil)
    case valeur(String)
    case interrupteur(Binding<Bool>)
    case aucun
}

/// Une ligne de réglage : pastille, libellé, et une valeur, un interrupteur ou une flèche.
struct LigneReglage: View {
    let icone: String
    let couleur: Color
    let libelle: String
    var accessoire: AccessoireReglage = .chevron()
    /// Une ligne de détail sous le libellé, en plus petit (1.10).
    var sousTitre: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Pastille(icone: icone, couleur: couleur)
            VStack(alignment: .leading, spacing: 1) {
                Text(libelle).texte(sousTitre == nil ? .corps : .corpsFort)
                    .foregroundStyle(Palette.textePrincipal).lineLimit(1)
                if let sousTitre {
                    Text(sousTitre).texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            switch accessoire {
            case .chevron(let valeur):
                if let valeur {
                    Text(valeur).texte(.corps).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.texteTertiaire)
            case .valeur(let valeur):
                Text(valeur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
            case .interrupteur(let actif):
                Toggle("", isOn: actif).labelsHidden().tint(theme.principal)
            case .aucun:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// Un groupe de lignes dans une carte, séparées par un filet.
struct GroupeReglages<Contenu: View>: View {
    @ViewBuilder var contenu: Contenu

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: contenu) { lignes in
                ForEach(Array(lignes.enumerated()), id: \.element.id) { element in
                    if element.offset > 0 {
                        Rectangle().fill(Palette.verreSeparateur).frame(height: 0.5).padding(.leading, 56)
                    }
                    element.element
                }
            }
        }
        .carte(rayon: Rayon.controle)
    }
}
