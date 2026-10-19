import SwiftUI

/// Tous les composants de C.4 sur un écran. Changer de combinaison en haut les
/// recolore tous : c'est la vérification du lot 4.
struct EcranComposants: View {
    @Environment(Apparence.self) private var apparence
    @State private var interrupteur = true
    @State private var charge = 62.5
    @State private var periode = 7
    @State private var cochee = false

    var body: some View {
        PagePoussee(titre: "Composants") {
            HStack(alignment: .top) {
                ForEach(Combinaison.allCases) { combinaison in
                    PastilleTheme(combinaison: combinaison, choisie: apparence.combinaison == combinaison) {
                        withAnimation(.smooth) {
                            apparence.couleursDeLaPhoto = false
                            apparence.combinaison = combinaison
                        }
                    }
                }
            }

            EnTeteGroupe(texte: "Boutons")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Accent") {}.buttonStyle(.hal(.accent))
                    Button("Verre") {}.buttonStyle(.hal(.verre))
                    Button("Accent doux") {}.buttonStyle(.hal(.verreAccent))
                }
                HStack {
                    Button("Retirer") {}.buttonStyle(.hal(.danger))
                    Button("Désactivé") {}.buttonStyle(.hal(.accent)).disabled(true)
                    BoutonRond("plus", libelle: "Ajouter") {}
                    BoutonRond("pencil", libelle: "Modifier") {}
                }
                Button("Grand bouton") {}.buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
            }

            EnTeteGroupe(texte: "Puces, anneaux, avatars")
            HStack(spacing: 8) {
                Puce("Cours", categorie: .cours)
                Puce("Sport", categorie: .sport)
                Puce("Ménage", categorie: .menage)
                Puce(texte: "dans 40 min")
            }
            HStack(spacing: 16) {
                Anneau(valeur: 2.0 / 3.0, texte: "2/3").frame(width: 56, height: 56)
                Anneau(valeur: 0.38, couleur: Categorie.linge.couleur, epaisseur: 8).frame(width: 56, height: 56)
                Avatar(nom: "Alex")
                Avatar(nom: "Sam", couleur: Categorie.chat.couleur)
                Orbe(etat: .repos)
                Orbe(etat: .recap)
            }

            EnTeteGroupe(texte: "Lignes")
            VStack(spacing: 10) {
                LigneEvenement(heure: "15:30", titre: "TD Algorithmique", lieu: "Salle 223", categorie: .cours)
                LigneEvenement(heure: "12:45", titre: "Course à pied", lieu: "5 km", categorie: .sport, passe: true)
                LigneTache(titre: "Litière", pourQui: "Sam", faite: cochee) { cochee.toggle() }
            }
            .padding(Espace.interne)
            .carte(rayon: Rayon.controle)
            GroupeReglages {
                LigneReglage(icone: "photo", couleur: Categorie.ia.couleur, libelle: "Avec flèche", accessoire: .chevron("Valeur"))
                LigneReglage(icone: "clock", couleur: Categorie.travail.couleur, libelle: "Avec valeur", accessoire: .valeur("07:00"))
                LigneReglage(icone: "bell", couleur: Categorie.alerte.couleur, libelle: "Avec interrupteur",
                             accessoire: .interrupteur($interrupteur))
            }

            EnTeteGroupe(texte: "Mesures et compteur")
            HStack(spacing: Espace.gouttiere) {
                Mesure(titre: "Sommeil", icone: "bed.double", valeur: "6 h 40", tendance: "semaine d'examens")
                Mesure(titre: "VFC", icone: "waveform", valeur: nil)
            }
            Compteur(titre: "Charge", valeur: $charge, pas: 0.5, unite: "kg", saisie: true)
            Segmente(choix: [(7, "7 jours"), (30, "30 jours"), (90, "90 jours")], selection: $periode)

            EnTeteGroupe(texte: "Graphiques")
            VStack(alignment: .leading, spacing: 10) {
                Courbe(points: Apercu().frequence)
                Barres(valeurs: [("Lun", 1), ("Mar", 0), ("Mer", 1), ("Jeu", 1), ("Ven", 0), ("Sam", 1), ("Dim", 0)])
            }
            .padding(Espace.interne)
            .carte(rayon: Rayon.controle)

            EnTeteGroupe(texte: "Bandeau")
            BandeauEtat(icone: "moon", titre: "Mode allégé · encore 2 jours",
                        detail: "Tu fais 1/4 des tâches partagées", categorie: .linge, bouton: "Arrêter")
        }
    }
}

/// Les états qu'on force pour essayer l'appli sans serveur.
struct EcranEssais: View {
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(ConversationHAL.self) private var conversation
    @Environment(Session.self) private var session
    @Environment(EnvoiSante.self) private var sante
    @State private var remplissage: String?

    var body: some View {
        @Bindable var foyer = foyer
        PagePoussee(titre: "États à forcer") {
            EnTeteGroupe(texte: "Aujourd'hui")
            GroupeReglages {
                bascule("Conflit de cours", "exclamationmark.circle", .alerte, $foyer.essais.conflit)
                bascule("Ajustement de HAL", "sparkle", .ia, $foyer.essais.ajustement)
                bascule("Mesure demandée", "scalemass", .ia, $foyer.essais.mesure)
                bascule("Jour de muscu", "dumbbell", .sport, $foyer.essais.jourDeMuscu)
                bascule("Compte neuf", "tray", .perso, $foyer.essais.foyerVide)
            }
            EnTeteGroupe(texte: "États qui durent")
            GroupeReglages {
                bascule("Hors réseau", "wifi.slash", .menage, $foyer.essais.horsReseau)
                bascule("Mode allégé", "moon", .linge, $foyer.essais.modeAllege)
                bascule("L'autre est absent", "mappin", .ia, $foyer.essais.absence)
                bascule("HAL en pause", "pause", .ia, $foyer.essais.pause)
            }
            EnTeteGroupe(texte: "HAL")
            Button("Le récap du soir est arrivé") { conversation.aQuelqueChoseADire = true }
                .buttonStyle(.hal(.verre, pleineLargeur: true))
            #if DEBUG && targetEnvironment(simulator)
            // SAN-11 à SAN-16 : Santé remplie d'une course inventée, puis envoyée.
            EnTeteGroupe(texte: "Santé (simulateur)")
            Button("Remplir Santé et envoyer") {
                Task {
                    do {
                        remplissage = try await RemplissageSante.remplir(sante.lecteur.store,
                                                                         lus: sante.lecteur.typesLus)
                        await sante.relireLAcces()
                        remplissage = (remplissage ?? "") + " " + (await sante.envoyer(raison: "essai", budget: 120))
                    } catch {
                        remplissage = "Échec : \(error.localizedDescription)"
                    }
                }
            }
            .buttonStyle(.hal(.verre, pleineLargeur: true))
            if let remplissage {
                Text(remplissage).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            #endif
            EnTeteGroupe(texte: "Premier lancement")
            Button("Revoir le premier lancement") { session.revoirAccueil() }
                .buttonStyle(.hal(.verre, pleineLargeur: true))
                .disabled(session.pseudo == nil)
            Text("Connecté seulement : Santé, notifications, calendriers et HAL, comme après une invitation.")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
            EnTeteGroupe(texte: "File d'attente")
            Text(file.enAttente.isEmpty ? "Rien en attente." : "\(file.enAttente.count) envoi(s) en attente du réseau.")
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            Button("Envoyer maintenant") { Task { await file.vider() } }
                .buttonStyle(.hal(.verre, pleineLargeur: true))
                .disabled(file.enAttente.isEmpty)
        }
    }

    private func bascule(_ libelle: String, _ icone: String, _ categorie: Categorie, _ valeur: Binding<Bool>) -> some View {
        LigneReglage(icone: icone, couleur: categorie.couleur, libelle: libelle,
                     accessoire: .interrupteur(valeur.animation(.snappy)))
    }
}
