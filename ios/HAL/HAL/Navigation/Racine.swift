import SwiftUI

/// Une confirmation qui flotte en haut cinq secondes, avec « Annuler » (ORB-6).
struct Annonce: Identifiable, Equatable {
    let id = UUID()
    let texte: String
    var annuler: (() -> Void)? = nil

    static func == (a: Annonce, b: Annonce) -> Bool { a.id == b.id }
}

/// L'écran racine : le fond, l'onglet choisi, le panneau de HAL et la barre.
/// Le panneau vit hors des onglets : il garde la conversation quand on en change (ORB-2).
struct Racine: View {
    @Environment(ConversationHAL.self) private var conversation
    @Environment(SeanceEnCours.self) private var seance
    @Environment(Foyer.self) private var foyer
    @Environment(Session.self) private var session
    @Environment(Aiguillage.self) private var aiguillage
    @State private var annonce: Annonce?

    private var onglet: Onglet { aiguillage.onglet }

    var body: some View {
        GeometryReader { geo in
            // Les quatre onglets restent en place, un seul visible : chacun garde
            // son défilement et ses écrans ouverts.
            ZStack {
                ForEach(Onglet.allCases) { candidat in
                    NavigationStack { ecran(candidat) }
                        .opacity(candidat == onglet ? 1 : 0)
                        .allowsHitTesting(candidat == onglet)
                        .accessibilityHidden(candidat != onglet)
                }
            }
            // La barre et le panneau flottent sur le contenu, qui défile dessous.
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if conversation.ouvert {
                        PanneauHAL()
                            .frame(height: hauteurPanneau(geo))
                            .padding(.horizontal, Espace.marge)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    BarreOnglets(selection: Bindable(aiguillage).onglet)
                }
                .padding(.bottom, 4)
            }
            // Chaque écran finit par une marge de la hauteur de ce qui flotte : le
            // dernier widget remonte au-dessus de la barre. Le panneau ouvert
            // l'agrandit, il pousse le contenu au lieu de le recouvrir (ORB-1).
            .environment(\.margeBasse, 68 + 4 + Espace.gouttiere
                         + (conversation.ouvert ? hauteurPanneau(geo) + 8 : 0))
        }
        .background { Fond() }
        .overlay(alignment: .top) {
            if let annonce {
                BandeauAnnonce(annonce: annonce) { self.annonce = nil }
                    .padding(.horizontal, Espace.marge)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // La séance en cours passe par-dessus tout, d'où qu'on l'ait lancée.
        .fullScreenCover(isPresented: Bindable(seance).affichee) { EcranSeanceEnCours() }
        // Le démarrage de HAL, depuis Sport, l'orbe ou Réglages (DEM-1).
        .fullScreenCover(isPresented: Bindable(conversation).demarrageOuvert) { EcranDemarrage() }
        // Ce qu'une carte de départ ou un widget vide propose, d'où qu'on soit (WID-8).
        .sheet(item: Bindable(aiguillage).feuille) { feuille in
            switch feuille {
            case .ajouterCalendrier:
                NavigationStack { FormulaireCalendrier() }.feuilleEnVerre()
            case .ajouterTache:
                NavigationStack { FormulaireTache() }.feuilleEnVerre()
            case .inviter:
                NavigationStack { EcranInvitation() }.feuilleEnVerre()
            }
        }
        // FOY-3 : une invitation crée un compte. Connecté, on ne s'en sert pas.
        .alert("Tu es déjà connecté", isPresented: Bindable(aiguillage).invitationRefusee) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Cette invitation crée un nouveau compte. Pour l'utiliser, déconnecte-toi d'abord de « \(session.pseudo ?? "") », dans Réglages, Serveur et connexion.")
        }
        .environment(\.annoncer, AnnonceurAction { nouvelle in
            withAnimation(.snappy) { annonce = nouvelle }
        })
        .onChange(of: onglet) { conversation.contexte = onglet.libelle }
        // IOS-2, IOS-3 : ce que les widgets et la Live Activity demandent d'ouvrir.
        .onChange(of: aiguillage.ouvrirHAL) { suivreLesLiens() }
        .onChange(of: aiguillage.ouvrirSeance) { suivreLesLiens() }
        .onAppear { suivreLesLiens() }
        // NOT-18 : le serveur dit que HAL a parlé, le « ! » s'allume.
        .onChange(of: foyer.orbeADire) { _, aDire in if aDire { conversation.signaler() } }
        .task(id: annonce?.id) {
            guard annonce != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.snappy) { annonce = nil }
        }
    }

    /// Un lien venu d'un widget, au lancement ou appli ouverte.
    private func suivreLesLiens() {
        if aiguillage.ouvrirHAL {
            aiguillage.ouvrirHAL = false
            conversation.ouvrir()
        }
        if aiguillage.ouvrirSeance {
            aiguillage.ouvrirSeance = false
            if seance.enCours { seance.affichee = true }
        }
    }

    private func hauteurPanneau(_ geo: GeometryProxy) -> CGFloat {
        geo.size.height * 0.52
    }

    @ViewBuilder
    private func ecran(_ onglet: Onglet) -> some View {
        switch onglet {
        case .aujourdhui: EcranAujourdhui()
        case .sport: EcranSport()
        case .maison: EcranMaison()
        case .reglages: EcranReglages()
        }
    }
}

/// Ce qu'un écran appelle pour afficher une confirmation.
struct AnnonceurAction {
    let action: (Annonce) -> Void
    func callAsFunction(_ texte: String, annuler: (() -> Void)? = nil) {
        action(Annonce(texte: texte, annuler: annuler))
    }
}

private struct CleAnnonceur: EnvironmentKey {
    static let defaultValue = AnnonceurAction { _ in }
}

extension EnvironmentValues {
    var annoncer: AnnonceurAction {
        get { self[CleAnnonceur.self] }
        set { self[CleAnnonceur.self] = newValue }
    }

    /// La hauteur de ce qui flotte en bas de l'écran : la barre, et le panneau de HAL s'il est ouvert.
    @Entry var margeBasse: CGFloat = 0
}

/// La confirmation en haut de l'écran. Un glissement vers le haut ou sur le
/// côté l'écarte tout de suite : elle ne doit jamais bloquer ce qui est dessous.
private struct BandeauAnnonce: View {
    let annonce: Annonce
    var fermer: () -> Void
    @Environment(\.theme) private var theme
    @State private var decalage: CGSize = .zero

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.principal)
            Text(annonce.texte).texte(.corps).foregroundStyle(Palette.textePrincipal).lineLimit(2)
            Spacer(minLength: 8)
            if let annuler = annonce.annuler {
                Button("Annuler") { annuler(); fermer() }.buttonStyle(.hal(.verre))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 52)
        .verreControle(Capsule())
        .offset(x: decalage.width, y: min(0, decalage.height))
        .opacity(1 - min(0.6, abs(decalage.width) / 300))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { geste in decalage = geste.translation }
                .onEnded { geste in
                    let haut = geste.predictedEndTranslation.height < -40
                    let cote = abs(geste.predictedEndTranslation.width) > 120
                    if haut || cote {
                        withAnimation(.snappy) {
                            decalage = CGSize(width: cote ? geste.predictedEndTranslation.width : 0,
                                              height: haut ? -200 : 0)
                        }
                        fermer()
                    } else {
                        withAnimation(.snappy) { decalage = .zero }
                    }
                }
        )
        .accessibilityAction(named: "Fermer") { fermer() }
    }
}
