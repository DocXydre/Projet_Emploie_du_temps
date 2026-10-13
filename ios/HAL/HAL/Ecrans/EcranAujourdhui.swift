import SwiftUI

/// Le tableau de bord (1.1). Les widgets prioritaires passent devant la
/// disposition choisie (WID-6) ; la séance libre ferme la grille (WID-7).
struct EcranAujourdhui: View {
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @State private var edition = false
    @State private var galerie = false
    @State private var ajoutRapide = false
    @State private var agrandi: Module?
    @State private var ecranOuvert: String?

    var body: some View {
        PageDefilante {
            EnTeteOnglet(surTitre: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)
                .locale(Locale(identifier: "fr_FR"))), titre: "Aujourd'hui") {
                if edition {
                    Button("OK") { withAnimation(.snappy) { edition = false } }.buttonStyle(.hal(.accent))
                } else {
                    BoutonRond("plus", libelle: "Ajouter") { ajoutRapide = true }
                    BoutonRond("pencil", libelle: "Modifier l'accueil") { withAnimation(.snappy) { edition = true } }
                }
            }
            .padding(.bottom, 4)

            Bandeaux()

            if foyer.essais.foyerVide {
                CartesDeDepart()
            }

            ForEach(prioritaires) { module in
                module.widget(.moyen)
                    .aspectRatio(2.07, contentMode: .fit)
                    .onTapGesture { ouvrir(module) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            TableauDeBord(edition: $edition, ouvrir: ouvrir, ajouter: { galerie = true })

        }
        .animation(.snappy, value: prioritaires.map(\.id))
        .overlay { vueAgrandie }
        .sheet(isPresented: $galerie) { Galerie() }
        .sheet(isPresented: $ajoutRapide) { AjoutRapide().presentationDetents([.medium, .large]) }
        .navigationDestination(item: $ecranOuvert) { id in
            Registre.module(id)?.ecran?()
        }
    }

    /// Les widgets qui passent en tête, dans l'ordre de WID-6.
    private var prioritaires: [Module] {
        var liste: [Module] = []
        if foyer.conflit != nil { liste.append(.conflit) }
        if foyer.ajustement != nil { liste.append(.ajustement) }
        if foyer.mesureDemandee != nil { liste.append(.mesureDemandee) }
        if foyer.seanceAPrevoir != nil { liste.append(.lancerSeance) }
        return liste
    }

    private func ouvrir(_ module: Module) {
        if module.ecran != nil {
            ecranOuvert = module.id
        } else if module.agrandi != nil {
            withAnimation(.spring(duration: 0.35)) { agrandi = module }
        }
    }

    /// Toucher un widget l'agrandit sur place, le reste se floute (WID-5).
    @ViewBuilder
    private var vueAgrandie: some View {
        if let module = agrandi, let vue = module.agrandi {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(duration: 0.3)) { agrandi = nil } }
                    .accessibilityLabel("Fermer")
                    .accessibilityAddTraits(.isButton)
                vue()
                    .padding(.horizontal, Espace.marge)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }
}

/// Les états qui durent, en bandeaux tout en haut (WID-6, 8.9, 8.13).
private struct Bandeaux: View {
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file

    var body: some View {
        if foyer.essais.horsReseau || !file.reseauDisponible {
            BandeauEtat(icone: "wifi.slash", titre: "Serveur injoignable",
                        detail: file.enAttente.isEmpty
                            ? "Données gardées sur le téléphone"
                            : "\(file.enAttente.count) en attente d'envoi",
                        categorie: .menage, bouton: "Réessayer") {
                Task { await file.vider() }
            }
        }
        if let refus = file.dernierRefus {
            BandeauEtat(icone: "exclamationmark.circle", titre: "Refusé par le serveur", detail: refus,
                        categorie: .alerte, bouton: "OK") { file.oublierRefus() }
        }
        if foyer.essais.modeAllege {
            BandeauEtat(icone: "moon", titre: "Mode allégé · encore 2 jours",
                        detail: "Tu fais 1/4 des tâches partagées jusqu'à jeudi",
                        categorie: .linge, bouton: "Arrêter") { foyer.essais.modeAllege = false }
        }
        if foyer.essais.absence, let autre = foyer.autre {
            BandeauEtat(icone: "mappin", titre: "\(autre.nom) est absent",
                        detail: "Retour ven. 18:40 · ses tâches sont à toi", categorie: .ia)
        }
    }
}

/// Ce que montre Aujourd'hui avant le premier calendrier et le démarrage de HAL (8.6).
private struct CartesDeDepart: View {
    @Environment(ConversationHAL.self) private var conversation

    var body: some View {
        carte(icone: "calendar", titre: "Ton planning est vide",
              texte: "Ajoute le lien de ta fac ou de ton agenda : HAL organise ta journée autour.",
              bouton: "Ajouter un calendrier") {}
        carte(icone: "sparkle", titre: "HAL n'a pas encore de plan",
              texte: "Quatre minutes de questions et il te propose quatre semaines.",
              bouton: "Démarrer HAL") { conversation.ouvrir() }
    }

    private func carte(icone: String, titre: String, texte: String, bouton: String,
                       action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icone).font(.system(size: 22)).foregroundStyle(Categorie.travail.couleur)
                .frame(width: 48, height: 48).background(Palette.verreTeinteForte, in: RoundedRectangle(cornerRadius: 14))
            Text(titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
            Text(texte).texte(.corps).foregroundStyle(Palette.texteSecondaire).multilineTextAlignment(.center)
            Button(bouton, action: action).buttonStyle(.hal(.accent))
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .carte()
    }
}
