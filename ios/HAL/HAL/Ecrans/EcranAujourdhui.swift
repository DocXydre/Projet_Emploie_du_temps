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

            // 8.6 : ce qui manque à un compte neuf, tant que ça manque (PRE-3).
            CarteDeDepart()

            ForEach(prioritaires) { module in
                module.widget(.moyen)
                    .aspectRatio(2.07, contentMode: .fit)
                    .onTapGesture { ouvrir(module) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            TableauDeBord(edition: $edition, ouvrir: ouvrir, ajouter: { galerie = true })

        }
        .refreshable { await foyer.charger() }
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
    @Environment(\.annoncer) private var annoncer
    @State private var trains: Proposition?

    var body: some View {
        BandeauServeur()
        if let allegement = foyer.monAllegement {
            BandeauEtat(icone: "moon", titre: "Mode allégé · \(restant(allegement.fin))",
                        detail: "Tu fais 1/4 des tâches partagées jusqu'au \(Self.jour(allegement.fin.addingTimeInterval(-3600)))",
                        categorie: .linge, bouton: "Arrêter") { arreterAllegement() }
        }
        if let absence = foyer.absenceDeLAutre {
            BandeauEtat(icone: "mappin",
                        titre: absence.debut <= .now ? "\(absence.pour.nom) est absent" : "\(absence.pour.nom) part bientôt",
                        detail: (absence.debut <= .now ? "Retour " : "Du \(Self.moment(absence.debut)) au ")
                            + Self.moment(absence.fin) + " · ses tâches passent à toi",
                        categorie: .ia)
        }
        ForEach(foyer.propositions) { proposition in
            BandeauEtat(icone: "tram", titre: "Un week-end à \(proposition.lieu) ?",
                        detail: "Du \(Self.jour(proposition.debut)) au \(Self.jour(proposition.fin))",
                        categorie: .travail, bouton: "Voir") { trains = proposition }
        }
        Color.clear.frame(height: 0)
            .sheet(item: $trains) { proposition in
                EcranTrains(proposition: proposition).presentationDetents([.large])
            }
    }

    private func arreterAllegement() {
        if !foyer.connecte {
            foyer.essais.modeAllege = false
            return
        }
        Task {
            do {
                try await foyer.agir("DELETE", "allegement")
                annoncer("Mode allégé arrêté")
            } catch {
                annoncer((error as? ErreurAPI)?.message ?? "Impossible d'arrêter")
            }
        }
    }

    private func restant(_ fin: Date) -> String {
        let jours = Calendar.current.dateComponents([.day], from: .now, to: fin).day ?? 0
        return jours <= 0 ? "jusqu'à ce soir" : "encore \(jours + 1) jours"
    }

    static func jour(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }

    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR")))
    }
}
