import SwiftUI

/// Le premier lancement, après la connexion ou l'invitation acceptée (8.1 à
/// 8.5) : l'accès à Santé, les notifications, les calendriers, la rencontre
/// avec HAL. Chaque écran explique avant que la fenêtre d'iOS ne s'ouvre
/// (PRE-2), et chacun a « Plus tard » (PRE-3) : ce qui est passé se rallume dans
/// Réglages, et Aujourd'hui le rappelle tant que c'est vide.
struct EcranPremierLancement: View {
    @Environment(Session.self) private var session
    @Environment(Foyer.self) private var foyer
    @Environment(EnvoiSante.self) private var sante
    @Environment(Notifications.self) private var notifications
    @Environment(ConversationHAL.self) private var conversation
    @State private var etape: Etape = .sante
    @State private var envoi = false
    @State private var ajout = false

    enum Etape: Int, CaseIterable {
        case sante, notifications, calendriers, hal
    }

    var body: some View {
        VStack(spacing: 0) {
            Avancee(etape: etape)
                .padding(.horizontal, Espace.marge)
                .padding(.top, Espace.serre)
            Group {
                switch etape {
                case .sante: pageSante
                case .notifications: pageNotifications
                case .calendriers: pageCalendriers
                case .hal: pageHAL
                }
            }
            .id(etape)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity))
        }
        .animation(.smooth(duration: 0.3), value: etape)
        .background { Fond() }
        .task {
            // Ce qui n'a rien à demander ne s'affiche pas : un iPhone sans Santé,
            // une autorisation déjà donnée sur cet appareil.
            await sante.relireLAcces()
            await notifications.relire()
            if etape == .sante && (!sante.disponible || sante.accesDemande) { suivante() }
        }
        .sheet(isPresented: $ajout) {
            NavigationStack {
                FormulaireCalendrier {
                    await foyer.charger()
                }
            }
            .feuilleEnVerre()
        }
    }

    // MARK: Les quatre écrans

    /// 8.1 : avant la fenêtre d'iOS (8.2), ce que HAL lit et pourquoi.
    private var pageSante: some View {
        PagePremierLancement(
            icone: "heart.fill", couleur: Categorie.alerte.couleur,
            titre: "Bienvenue, \(prenom)",
            texte: "HAL lit ce que ta montre et ton iPhone mesurent, pour doser tes séances : une mauvaise nuit allège la journée, une semaine chargée aussi. Rien n'est écrit dans Santé, et rien n'en sort hors de ton compte.",
            bouton: "Autoriser Santé", enCours: envoi,
            action: {
                envoi = true
                await sante.demanderAcces()
                envoi = false
                suivante()
            },
            plusTard: { suivante() }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(EnvoiSante.Donnee.allCases) { donnee in
                    Label(donnee.libelle, systemImage: donnee.icone)
                        .texte(.corps)
                        .foregroundStyle(Palette.textePrincipal)
                        .labelStyle(EtiquetteIcone(couleur: Categorie.alerte.couleur))
                }
            }
            .padding(Espace.interne)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte(rayon: Rayon.controle)
            Text("iOS ouvre ensuite sa fenêtre : touche « Tout activer », puis « Autoriser ». Tu pourras décocher une donnée dans Réglages, Santé.")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
        }
    }

    /// 8.3 : les notifications, avant de les demander.
    private var pageNotifications: some View {
        PagePremierLancement(
            icone: "bell.badge.fill", couleur: Categorie.menage.couleur,
            titre: "Les notifications",
            texte: "Le matin, ta journée. Le soir, ce qui reste à cocher. HAL te dit quand il ajuste une séance, et chaque changement du planning arrive avec sa raison. Rien pendant la nuit.",
            bouton: notifications.etat == .aDemander ? "Activer les notifications" : "Continuer",
            enCours: envoi,
            action: {
                if notifications.etat == .aDemander {
                    envoi = true
                    await notifications.demander()
                    envoi = false
                }
                suivante()
            },
            plusTard: notifications.etat == .aDemander ? { suivante() } : nil
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ligne("sun.max", "Bilan du matin", "7 h")
                ligne("moon", "Relance du soir", "21 h")
                ligne("sparkle", "Récap de HAL", "23 h")
                ligne("moon.zzz", "Silence", "23 h 30 à 7 h 30")
            }
            .padding(Espace.interne)
            .carte(rayon: Rayon.controle)
            Text(notifications.etat == .refusees
                 ? "Elles sont refusées sur cet iPhone : iOS seul peut les rallumer, dans ses Réglages."
                 : "Ces heures se changent dans Réglages, Notifications et heures.")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
        }
    }

    /// 8.4 : un premier calendrier, pour que le planning ait de quoi s'organiser.
    private var pageCalendriers: some View {
        let dejaSuivis = foyer.calendriersSuivis ?? 0
        return PagePremierLancement(
            icone: "calendar", couleur: Categorie.travail.couleur,
            titre: "Ton emploi du temps",
            texte: "Colle le lien de ta fac, de ton travail ou de ton agenda. Le ménage et le sport se placent dans tes creux, et le planning suit quand un cours bouge.",
            bouton: dejaSuivis == 0 ? "Ajouter un calendrier" : "Continuer",
            enCours: false,
            action: {
                if dejaSuivis == 0 { ajout = true } else { suivante() }
            },
            plusTard: dejaSuivis == 0 ? { suivante() } : nil
        ) {
            if dejaSuivis > 0 {
                Label("Tu suis déjà \(dejaSuivis) calendrier\(dejaSuivis > 1 ? "s" : "").", systemImage: "checkmark.circle.fill")
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .labelStyle(EtiquetteIcone(couleur: Categorie.sport.couleur))
                Button("Ajouter un autre calendrier") { ajout = true }.buttonStyle(.hal(.verre))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ligne("graduationcap", "Cours", "L'emploi du temps de la fac, de l'ADE")
                    ligne("briefcase", "Travail", "Un planning publié en lien")
                    ligne("calendar", "Perso", "Calendrier, Google Agenda, Outlook")
                }
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
            }
        }
    }

    /// 8.5 : rencontrer HAL, puis son démarrage, ou découvrir l'appli d'abord (PRE-4).
    private var pageHAL: some View {
        // Tant que Sport n'a pas répondu, on propose le démarrage : il sait reprendre.
        let aDemarrer = foyer.sportDuServeur.map { $0.demarrage != nil } ?? true
        return PagePremierLancement(
            orbe: true, couleur: Categorie.ia.couleur,
            titre: aDemarrer ? "Rencontre HAL" : "HAL est prêt",
            texte: aDemarrer
                ? "Ton coach sportif. Quelques questions sur toi, tes limites, tes lieux et ton objectif, et il te propose quatre semaines. Il ne touche qu'au sport : le ménage et le planning restent à vous."
                : "Ton plan t'attend dans Sport. Touche l'orbe en bas de l'écran pour lui parler, d'où que tu sois.",
            bouton: aDemarrer ? "Démarrer HAL" : "Ouvrir l'appli",
            enCours: false,
            action: {
                session.accueilFait()
                guard aDemarrer else { return }
                // Le démarrage s'ouvre par-dessus l'appli, une fois celle-ci affichée.
                try? await Task.sleep(for: .milliseconds(450))
                conversation.demarrageOuvert = true
            },
            plusTard: aDemarrer ? { session.accueilFait() } : nil,
            libellePlusTard: "Découvrir l'appli d'abord"
        ) {
            if aDemarrer {
                Text("Cinq étapes, quelques minutes. Tu peux t'arrêter en route : Sport te proposera de reprendre là où tu en étais (DEM-4).")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire)
            }
        }
    }

    /// Le prénom du compte, une fois le serveur lu ; son pseudo en attendant.
    private var prenom: String {
        foyer.charge ? foyer.moi.nom : (session.pseudo ?? "").capitalized
    }

    private func ligne(_ icone: String, _ titre: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icone).foregroundStyle(Categorie.ia.couleur).frame(width: 22)
            Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            Spacer(minLength: 8)
            Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire).multilineTextAlignment(.trailing)
        }
    }

    private func suivante() {
        if let prochaine = Etape(rawValue: etape.rawValue + 1) {
            etape = prochaine
        } else {
            session.accueilFait()
        }
    }
}

/// Les quatre traits de l'avancée.
private struct Avancee: View {
    let etape: EcranPremierLancement.Etape

    var body: some View {
        HStack(spacing: 6) {
            ForEach(EcranPremierLancement.Etape.allCases, id: \.rawValue) { candidate in
                Capsule()
                    .fill(candidate.rawValue <= etape.rawValue ? Categorie.ia.couleur : Palette.verreTeinteForte)
                    .frame(height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Étape \(etape.rawValue + 1) sur \(EcranPremierLancement.Etape.allCases.count)")
    }
}

/// Un écran du premier lancement : une icône ou l'orbe, le titre, ce qu'on
/// explique, puis le bouton qui agit et « Plus tard » en bas.
private struct PagePremierLancement<Contenu: View>: View {
    var icone: String? = nil
    var orbe = false
    let couleur: Color
    let titre: String
    let texte: String
    let bouton: String
    let enCours: Bool
    let action: () async -> Void
    var plusTard: (() -> Void)? = nil
    var libellePlusTard = "Plus tard"
    @ViewBuilder var contenu: Contenu

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                Group {
                    if orbe {
                        Orbe(etat: .repos, taille: 84).frame(width: 84, height: 84)
                    } else if let icone {
                        Image(systemName: icone)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(couleur)
                            .frame(width: 72, height: 72)
                            .background(couleur.opacity(0.18), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }
                .padding(.top, 24)
                .accessibilityHidden(true)
                Text(titre).texte(.grandTitre).foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(texte).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
                contenu
            }
            .padding(Espace.marge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Button {
                    Task { await action() }
                } label: {
                    HStack {
                        if enCours { ProgressView() }
                        Text(bouton)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                .disabled(enCours)
                if let plusTard {
                    Button(libellePlusTard, action: plusTard)
                        .buttonStyle(.plain)
                        .texte(.corpsFort)
                        .foregroundStyle(Palette.texteSecondaire)
                        .frame(height: 44)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 8)
        }
    }
}
