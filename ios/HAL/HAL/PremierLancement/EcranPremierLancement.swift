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
    @State private var calendriers: [CalendrierSuivi] = []

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
                    await chargerCalendriers()
                }
            }
            .feuilleEnVerre()
        }
    }

    // MARK: Les quatre écrans

    /// 8.1 : avant la fenêtre d'iOS (8.2), ce que HAL lit et pourquoi.
    private var pageSante: some View {
        PagePremierLancement(
            icone: "heart", couleur: Categorie.alerte.couleur,
            titre: "Relier Santé",
            texte: "HAL lit ce que mesurent ta montre et ton iPhone pour adapter tes séances.",
            bouton: "Autoriser l'accès à Santé", enCours: envoi,
            action: {
                envoi = true
                await sante.demanderAcces()
                envoi = false
                suivante()
            },
            plusTard: { suivante() }
        ) {
            Points {
                Point(icone: "shoeprints.fill", texte: "Pas, sommeil, fréquence cardiaque, VFC")
                Point(icone: "waveform.path.ecg", texte: "Tes séances de la montre, pour valider les courses")
                Point(icone: "lock", texte: "Tout reste sur ton serveur, jamais partagé")
            }
            Text("iOS ouvre ensuite sa fenêtre : touche « Tout activer », puis « Autoriser ». Rien n'est écrit dans Santé.")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                .multilineTextAlignment(.center)
        }
    }

    /// 8.3 : les notifications, avant de les demander.
    private var pageNotifications: some View {
        PagePremierLancement(
            icone: "bell", couleur: Categorie.menage.couleur,
            titre: "Être prévenu",
            texte: "C'est par là que l'appli te parle, puisqu'il n'y a plus de bot.",
            bouton: notifications.etat == .aDemander ? "Autoriser les notifications" : "Continuer",
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
            Points {
                Point(orbe: true, texte: "Le récap du soir et les propositions de HAL")
                Point(icone: "checklist",
                      texte: foyer.autre.map { "Tes tâches du jour, et quand \($0.nom) fait la tienne" }
                          ?? "Tes tâches du jour")
                Point(icone: "calendar", texte: "Les changements de planning, avec la raison")
                Point(icone: "moon", texte: "Rien entre 23:30 et 7:30")
            }
            if notifications.etat == .refusees {
                Text("Elles sont refusées sur cet iPhone : iOS seul peut les rallumer, dans ses Réglages.")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// 8.4 : les calendriers suivis, et de quoi en ajouter un.
    private var pageCalendriers: some View {
        PagePremierLancement(
            icone: "calendar", couleur: Categorie.travail.couleur,
            titre: "Ton emploi du temps",
            texte: "Colle le lien de tes calendriers : la fac, ton agenda perso. HAL place tout autour.",
            bouton: calendriers.isEmpty ? "Ajouter un lien" : "Continuer",
            enCours: false,
            action: {
                if calendriers.isEmpty { ajout = true } else { suivante() }
            },
            plusTard: { suivante() },
            libellePlusTard: "Je le ferai plus tard"
        ) {
            if !calendriers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(calendriers.enumerated()), id: \.element.id) { rang, calendrier in
                        HStack(spacing: 12) {
                            Image(systemName: calendrier.lienDonne ? "checkmark" : "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(calendrier.lienDonne ? Categorie.sport.couleur : Palette.texteSecondaire)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(calendrier.libelle).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                Text(calendrier.lienDonne ? "\(calendrier.aVenir) à venir" : "à ajouter")
                                    .texte(.legende)
                                    .foregroundStyle(calendrier.lienDonne ? Categorie.sport.couleur : Palette.texteSecondaire)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        if rang < calendriers.count - 1 { Divider().overlay(Palette.verreBord) }
                    }
                }
                .padding(.horizontal, Espace.interne)
                .carte(rayon: Rayon.controle)
                Button("Ajouter un lien") { ajout = true }
                    .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
            } else {
                Points {
                    Point(icone: "graduationcap", texte: "Les cours, depuis l'ADE de la fac")
                    Point(icone: "briefcase", texte: "Un planning de travail publié en lien")
                    Point(icone: "calendar", texte: "Ton agenda : Calendrier, Google, Outlook")
                }
            }
        }
        .task { await chargerCalendriers() }
    }

    /// 8.5 : rencontrer HAL, puis son démarrage, ou découvrir l'appli d'abord (PRE-4).
    private var pageHAL: some View {
        // Tant que Sport n'a pas répondu, on propose le démarrage : il sait reprendre.
        let aDemarrer = foyer.sportDuServeur.map { $0.demarrage != nil } ?? true
        return PagePremierLancement(
            orbe: true, couleur: Categorie.ia.couleur,
            titre: aDemarrer ? "Et maintenant, HAL" : "HAL est prêt",
            texte: aDemarrer
                ? "Ton coach sportif. Quatre minutes de questions et il te prépare un plan. Il ne touche qu'au sport : le ménage et le planning restent à vous."
                : "Ton plan t'attend dans Sport. Touche l'orbe en bas de l'écran pour lui parler, d'où que tu sois.",
            bouton: aDemarrer ? "Faire le démarrage de HAL" : "Ouvrir l'appli",
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
            EmptyView()
        }
    }

    private func chargerCalendriers() async {
        guard foyer.connecte else { return }
        let tous: [CalendrierSuivi] = (try? await foyer.demander("GET", "appli/calendriers")) ?? []
        calendriers = tous.filter { $0.pour == foyer.moi.id || !foyer.charge }
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
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(EcranPremierLancement.Etape.allCases, id: \.rawValue) { candidate in
                Capsule()
                    .fill(candidate.rawValue <= etape.rawValue ? theme.principal : Palette.verreTeinteForte)
                    .frame(height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Étape \(etape.rawValue + 1) sur \(EcranPremierLancement.Etape.allCases.count)")
    }
}

/// Un écran du premier lancement [8.1 à 8.5] : une grande icône pleine ou
/// l'orbe, le titre et ce qu'on explique, centrés, puis une carte de points, et
/// en bas le bouton qui agit et « Plus tard ».
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
            VStack(spacing: Espace.gouttiere) {
                Group {
                    if orbe {
                        Orbe(etat: .repos, taille: 96).frame(width: 96, height: 96)
                    } else if let icone {
                        Image(systemName: icone)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 96, height: 96)
                            .background(couleur, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                }
                .padding(.top, 40)
                .accessibilityHidden(true)
                Text(titre).texte(.grandTitre).foregroundStyle(Palette.textePrincipal)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .surLaPhoto()
                    .accessibilityAddTraits(.isHeader)
                Text(texte).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .surLaPhoto()
                contenu
            }
            .padding(Espace.marge)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
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
                        .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 8)
        }
    }
}

/// La carte des points d'un écran du premier lancement.
private struct Points<Contenu: View>: View {
    @ViewBuilder var contenu: Contenu

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { contenu }
            .padding(Espace.interne)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte(rayon: Rayon.controle)
    }
}

/// Un point : une icône, ou l'orbe pour ce qui vient de HAL, et une phrase.
private struct Point: View {
    var icone: String? = nil
    var orbe = false
    let texte: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if orbe {
                    Orbe(etat: .repos, taille: 18)
                } else if let icone {
                    Image(systemName: icone).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.texteSecondaire)
                }
            }
            .frame(width: 22, height: 20)
            Text(texte).texte(.corps).foregroundStyle(Palette.textePrincipal)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
