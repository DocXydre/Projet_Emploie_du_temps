import SwiftUI

/// Le tableau de bord (1.1). Les widgets prioritaires passent devant la
/// disposition choisie (WID-6).
struct EcranAujourdhui: View {
    @Environment(Foyer.self) private var foyer
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @State private var edition = false
    @State private var galerie = false
    @State private var ajoutRapide = false
    @State private var agrandi: Module?
    @State private var ecranOuvert: String?

    var body: some View {
        PageDefilante {
            if edition {
                // 1.9 : le mode édition ne montre que ce qui se déplace.
                ZStack {
                    Text("Modifier l'accueil").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                        .surLaPhoto()
                    HStack {
                        BoutonRond("plus", libelle: "Ajouter un widget") { galerie = true }
                        Spacer()
                        Button("Terminé") { withAnimation(.snappy) { edition = false } }
                            .buttonStyle(.hal(.accent))
                    }
                }
                .frame(height: 44)
                .padding(.bottom, 4)
            } else {
                EnTeteOnglet(surTitre: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)
                    .locale(Locale(identifier: "fr_FR"))), titre: "Aujourd'hui") {
                    BoutonRond("plus", libelle: "Ajouter") { ajoutRapide = true }
                    BoutonRond("pencil", libelle: "Modifier l'accueil") { withAnimation(.snappy) { edition = true } }
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
            }

            TableauDeBord(edition: $edition, ouvrir: ouvrir, ajouter: { galerie = true })

        }
        .overlay(alignment: .bottom) {
            if edition {
                Label("Glisse pour déplacer · touche le coin pour la taille",
                      systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .texte(.legende).foregroundStyle(Palette.textePrincipal)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .verreControle(Capsule(), interactif: false)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .refreshable { await foyer.charger() }
        .animation(.snappy, value: prioritaires.map(\.id))
        .overlay { vueAgrandie }
        .sheet(isPresented: $galerie) { Galerie() }
        .sheet(isPresented: $ajoutRapide) { AjoutRapide().presentationDetents([.fraction(0.64), .large]) }
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
        if !foyer.effortsADonner.isEmpty { liste.append(.effortADonner) }
        // Une séance lancée passe devant tout le reste, puis celle du jour à lancer.
        if seance.enCours {
            liste.insert(.seanceEnCours, at: 0)
        } else if foyer.seanceAPrevoir != nil {
            liste.append(.lancerSeance)
        }
        return liste
    }

    private func ouvrir(_ module: Module) {
        if module.id == Module.seanceEnCours.id {
            seance.affichee = true
        } else if module.ecran != nil {
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
                    .environment(\.fermerAgrandi, ActionFermer {
                        withAnimation(.spring(duration: 0.3)) { agrandi = nil }
                    })
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
    @State private var demandesOuvertes = false

    var body: some View {
        BandeauServeur()
        if !foyer.demandes.isEmpty {
            // ACC-13 : ce qu'un modèle a demandé attend, en tête de l'accueil.
            let n = foyer.demandes.count
            BandeauEtat(icone: "hand.raised",
                        titre: n == 1 ? "Une demande à accepter" : "\(n) demandes à accepter",
                        detail: n == 1 ? foyer.demandes[0].resume
                            : "De \(Set(foyer.demandes.map(\.auteur)).sorted().joined(separator: " et "))",
                        categorie: .ia, bouton: "Voir") { demandesOuvertes = true }
                .sheet(isPresented: $demandesOuvertes) {
                    NavigationStack { EcranDemandes() }.feuilleEnVerre()
                }
        }
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
        // Les week-ends proposés sont un widget de l'accueil (WID, 1.13), pas un état.
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
