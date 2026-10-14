import SwiftUI

extension Module {
    static let maintenant = Module(
        id: "maintenant", nom: "Maintenant", icone: "calendar", categorie: .cours,
        tailles: [.moyen],
        widget: { _ in AnyView(WidgetMaintenant()) },
        agrandi: { AnyView(WidgetTaJournee(taille: .grand).frame(height: 360)) },
        pourHAL: { foyer in foyer.maintenant.map { "Maintenant : \($0.titre)" } ?? "Rien en cours" }
    )

    static let taJournee = Module(
        id: "taJournee", nom: "Ta journée", icone: "clock", categorie: .travail,
        tailles: [.moyen, .grand],
        widget: { taille in AnyView(WidgetTaJournee(taille: taille)) },
        agrandi: { AnyView(WidgetTaJournee(taille: .grand).frame(height: 360)) },
        pourHAL: { foyer in "Journée : " + foyer.evenementsDuJour.map(\.titre).joined(separator: ", ") }
    )

    static let conflit = Module(
        id: "conflit", nom: "À choisir", icone: "exclamationmark.circle", categorie: .alerte,
        tailles: [.moyen],
        widget: { _ in AnyView(WidgetConflit(agrandi: false)) },
        agrandi: { AnyView(WidgetConflit(agrandi: true)) }
    )
}

/// L'événement en cours ou le prochain, et ce qui suit.
struct WidgetMaintenant: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        CoquilleWidget(.maintenant) {
            if let evenement = foyer.maintenant {
                VStack(alignment: .leading, spacing: 4) {
                    Text(evenement.titre).texte(.titre).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                    Text(horaire(evenement)).texte(.corps).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Puce(texte: delai(evenement), couleur: Categorie.travail.couleur, fond: Categorie.travail.voile)
                        if let ensuite = foyer.ensuite {
                            Text("Ensuite : \(ensuite.titre) · \(ensuite.debut.formatted(date: .omitted, time: .shortened))")
                                .texte(.legende).foregroundStyle(Palette.texteTertiaire).lineLimit(1)
                        }
                    }
                }
            } else {
                VideWidget(texte: "Rien de prévu pour le reste de la journée.")
            }
        }
    }

    private func horaire(_ evenement: Evenement) -> String {
        var texte = evenement.debut.formatted(date: .omitted, time: .shortened)
        if let fin = evenement.fin { texte += " – " + fin.formatted(date: .omitted, time: .shortened) }
        if let lieu = evenement.lieu { texte += " · " + lieu }
        return texte
    }

    private func delai(_ evenement: Evenement) -> String {
        let minutes = Int(evenement.debut.timeIntervalSinceNow / 60)
        if minutes <= 0 { return "en cours" }
        if minutes < 60 { return "dans \(minutes) min" }
        return "dans \(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }
}

/// La journée heure par heure, toutes familles.
struct WidgetTaJournee: View {
    let taille: TailleWidget
    @Environment(Foyer.self) private var foyer
    @Environment(Aiguillage.self) private var aiguillage

    var body: some View {
        CoquilleWidget(.taJournee) {
            let evenements = foyer.evenementsDuJour
            if evenements.isEmpty && foyer.sansCalendrier {
                VideWidget(texte: "Ajoute un calendrier pour voir ta journée.", bouton: "Ajouter") {
                    aiguillage.feuille = .ajouterCalendrier
                }
            } else if evenements.isEmpty {
                VideWidget(texte: "Rien de prévu aujourd'hui.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(evenements.prefix(taille == .grand ? 10 : 4)) { evenement in
                        LigneEvenement(heure: evenement.heure,
                                       titre: evenement.titre, lieu: evenement.lieu,
                                       categorie: evenement.categorie,
                                       passe: (evenement.fin ?? evenement.debut) < .now)
                    }
                }
            }
        }
    }
}

/// Deux cours qui se chevauchent : on touche celui à garder (COL-12, COL-23).
struct WidgetConflit: View {
    let agrandi: Bool
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var choix: Conflit.Cours?
    @State private var envoi = false

    var body: some View {
        if let conflit = foyer.conflit {
            CoquilleWidget(titre: "À choisir · \(conflit.jour)", icone: "exclamationmark.circle",
                           couleur: Categorie.alerte.couleur) {
                if agrandi { detail(conflit) } else { resume(conflit) }
            }
        }
    }

    /// En tête d'Aujourd'hui [1.3] : on touche le cours à garder, c'est réglé.
    private func resume(_ conflit: Conflit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deux cours en même temps à \(conflit.premier.horaire.prefix(5))")
                .texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
            HStack(spacing: 8) {
                ForEach([conflit.premier, conflit.second], id: \.self) { cours in
                    Button { garder(cours) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cours.titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Text("garder").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: Rayon.ligne))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(envoi)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Button("Voir plus tard") { foyer.remettreAPlusTard() }
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                .buttonStyle(.plain)
        }
    }

    /// Agrandi [8.15] : les horaires et les salles, puis on valide.
    private func detail(_ conflit: Conflit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deux cours à \(conflit.premier.horaire.prefix(5))").texte(.titre).foregroundStyle(Palette.textePrincipal)
            Text("Le flux de la fac a deux cours en même temps. Garde celui où tu vas : le choix est retenu pour les prochaines fois.")
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            ForEach([conflit.premier, conflit.second], id: \.self) { cours in
                Button { choix = cours } label: {
                    HStack(spacing: 10) {
                        Image(systemName: choix == cours ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(choix == cours ? Categorie.sport.couleur : Palette.texteSecondaire)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(cours.titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                            Text(cours.salle.isEmpty ? cours.horaire : "\(cours.horaire) · \(cours.salle)")
                                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: Rayon.ligne))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Garder ce cours") { if let choix { garder(choix) } }
                    .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                    .disabled(choix == nil || envoi)
                Button("Voir plus tard") { foyer.remettreAPlusTard() }
                    .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
            }
            Text("« Voir plus tard » le cache ; s'il n'est pas réglé, il revient au prochain chargement.")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
        }
    }

    private func garder(_ choix: Conflit.Cours) {
        envoi = true
        Task {
            defer { envoi = false }
            do {
                try await foyer.choisir(choix)
                annoncer("« \(choix.titre) » gardé")
            } catch {
                annoncer((error as? ErreurAPI)?.message ?? "Choix impossible")
            }
        }
    }
}

/// Ce qu'un widget dit quand il n'a rien à montrer : ce qui manque, et comment
/// l'obtenir en un bouton (WID-8).
struct VideWidget: View {
    let texte: String
    var bouton: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            Text(texte)
                .texte(.corps)
                .foregroundStyle(Palette.texteSecondaire)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
            if let bouton {
                Button(bouton, action: action).buttonStyle(.hal(.verreAccent))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
