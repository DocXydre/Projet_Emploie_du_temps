import SwiftUI

// Les états vides et les erreurs (8.6 à 8.9), partagés par les onglets : le
// bandeau du serveur, les choses à faire d'un compte neuf, et l'onglet vide qui
// dit ce qui manque et comment l'obtenir (WID-8, PRE-3).

/// 8.9 : le serveur ne répond pas, ou ne reconnaît plus la clé. L'appli garde
/// les dernières données et dit de quand elles datent (APP-2) ; ce qu'on fait
/// attend dans la file (APP-3).
struct BandeauServeur: View {
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(Session.self) private var session

    var body: some View {
        if foyer.cleRefusee {
            BandeauEtat(icone: "person.crop.circle.badge.xmark", titre: "Connexion refusée",
                        detail: "Le serveur ne reconnaît plus ce compte : reconnecte-toi.",
                        categorie: .alerte, bouton: "Se reconnecter") {
                file.vider(sansEnvoyer: true)
                session.deconnecter()
            }
        } else if foyer.essais.horsReseau || !file.reseauDisponible || foyer.injoignable {
            BandeauEtat(icone: "wifi.slash", titre: "Serveur injoignable", detail: detailHorsReseau,
                        categorie: .menage, bouton: "Réessayer") {
                Task {
                    await file.vider()
                    await foyer.charger()
                }
            }
        } else if let erreur = foyer.erreur {
            BandeauEtat(icone: "exclamationmark.icloud", titre: "Pas à jour", detail: erreur,
                        categorie: .menage, bouton: "Réessayer") {
                Task { await foyer.charger() }
            }
        }
        if let refus = file.dernierRefus {
            BandeauEtat(icone: "exclamationmark.circle", titre: "Refusé par le serveur", detail: refus,
                        categorie: .alerte, bouton: "OK") { file.oublierRefus() }
        }
    }

    /// « Données de 14:32 · 2 en attente d'envoi ».
    private var detailHorsReseau: String {
        var morceaux = [foyer.misAJour.map(Self.donnees) ?? "Données gardées sur le téléphone"]
        if !file.enAttente.isEmpty { morceaux.append("\(file.enAttente.count) en attente d'envoi") }
        return morceaux.joined(separator: " · ")
    }

    /// « Données de 14:32 », « Données d'hier, 18:05 », « Données du 12 oct., 9:10 ».
    static func donnees(_ date: Date) -> String {
        let heure = date.formatted(date: .omitted, time: .shortened)
        let calendrier = Calendar.current
        if calendrier.isDateInToday(date) { return "Données de \(heure)" }
        if calendrier.isDateInYesterday(date) { return "Données d'hier, \(heure)" }
        let jour = date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
        return "Données du \(jour), \(heure)"
    }
}

/// 8.6 : ce qu'un compte neuf a encore à faire, en tête d'Aujourd'hui. Chaque
/// ligne disparaît quand c'est fait, la carte avec la dernière (PRE-3).
struct CarteDeDepart: View {
    @Environment(Foyer.self) private var foyer
    @Environment(EnvoiSante.self) private var sante
    @Environment(Notifications.self) private var notifications
    @Environment(ConversationHAL.self) private var conversation
    @Environment(Aiguillage.self) private var aiguillage
    @State private var envoi = false

    private struct Etape: Identifiable {
        let id: String
        let icone: String
        let categorie: Categorie
        let titre: String
        let texte: String
        let bouton: String
        let action: () async -> Void
    }

    var body: some View {
        let reste = etapes
        if !reste.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pour bien démarrer").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                    Text(reste.count == 1 ? "Encore une chose." : "\(reste.count) choses à faire, dans l'ordre que tu veux.")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                ForEach(reste) { etape in
                    HStack(alignment: .top, spacing: 12) {
                        Pastille(icone: etape.icone, couleur: etape.categorie.couleur)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(etape.titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                            Text(etape.texte).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(etape.bouton) {
                                Task {
                                    envoi = true
                                    await etape.action()
                                    envoi = false
                                }
                            }
                            .buttonStyle(.hal(.verreAccent))
                            .disabled(envoi)
                            .padding(.top, 6)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(Espace.interne)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte()
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var etapes: [Etape] {
        var liste: [Etape] = []
        if foyer.sansCalendrier {
            liste.append(Etape(id: "calendrier", icone: "calendar", categorie: .travail,
                               titre: "Ajoute ton emploi du temps",
                               texte: "Le lien de ta fac, de ton travail ou de ton agenda : ta journée s'affiche, et le ménage se place dans tes creux.",
                               bouton: "Ajouter un calendrier") { aiguillage.feuille = .ajouterCalendrier })
        }
        if let bloc = foyer.demarrageDeHAL {
            liste.append(Etape(id: "hal", icone: "sparkle", categorie: .ia,
                               titre: bloc == "profil" ? "Rencontre HAL" : "Finis le démarrage de HAL",
                               texte: bloc == "profil"
                                   ? "Quelques questions, et ton coach te propose quatre semaines de sport."
                                   : "Il reste \(EcranDemarrage.nomDuBloc(bloc)) ; tes réponses sont gardées.",
                               bouton: bloc == "profil" ? "Démarrer HAL" : "Reprendre") { conversation.demarrageOuvert = true })
        }
        if foyer.connecte && sante.disponible && !sante.accesDemande {
            liste.append(Etape(id: "sante", icone: "heart", categorie: .alerte,
                               titre: "Autorise Santé",
                               texte: "Ton sommeil et ta fréquence cardiaque aident HAL à doser tes séances. Rien n'est écrit dans Santé.",
                               bouton: "Autoriser") { await sante.demanderAcces() })
        }
        if foyer.connecte && notifications.etat == .aDemander {
            liste.append(Etape(id: "notifications", icone: "bell", categorie: .menage,
                               titre: "Active les notifications",
                               texte: "Ta journée le matin, ce qui reste le soir, et chaque changement avec sa raison.",
                               bouton: "Activer") { await notifications.demander() })
        }
        return liste
    }
}

/// 8.7, 8.8 : un onglet sans contenu dit ce qui manque, et comment l'obtenir en un bouton (WID-8).
struct CarteVide: View {
    let icone: String
    let categorie: Categorie
    let titre: String
    let texte: String
    var bouton: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icone).font(.system(size: 22)).foregroundStyle(categorie.couleur)
                .frame(width: 48, height: 48)
                .background(Palette.verreTeinteForte, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(titre).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                .multilineTextAlignment(.center)
            Text(texte).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let bouton {
                Button(bouton, action: action).buttonStyle(.hal(.accent))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .carte()
        .accessibilityElement(children: .combine)
    }
}
