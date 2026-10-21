import SwiftUI
import UIKit

// Réglages, groupes « Appareil » et « Foyer et compte » (5.11, 5.13, 5.15,
// 5.16) : les notifications et mes heures, le serveur et la connexion, le
// foyer, ses membres, ses droits et ses invitations.

private let enFrancais = Locale(identifier: "fr_FR")

private func motifDe(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

private struct LigneRefus: View {
    let texte: String?

    var body: some View {
        if let texte {
            Section {
                Label(texte, systemImage: "exclamationmark.circle").foregroundStyle(Categorie.alerte.couleur)
            }
        }
    }
}

// MARK: - 5.15 Le foyer

/// Les membres, inviter, les droits sur les tâches, passer l'administration,
/// retirer, quitter (FOY-2, FOY-5 à FOY-7). Ce qui revient à l'administrateur
/// du foyer ne s'affiche que pour lui ; la base refuse de toute façon le reste.
struct EcranFoyer: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var lu: FoyerLu?
    @State private var sansFoyer = false
    @State private var erreur: String?
    @State private var nom = ""
    @State private var invitation = false
    @State private var aRetirer: FoyerLu.MembreLu?
    @State private var aPromouvoir: FoyerLu.MembreLu?
    @State private var quitter = false
    @State private var envoi = false

    var body: some View {
        FormulaireVerre {
            if !foyer.connecte {
                Section {
                    Label("En démonstration, le foyer est fictif. Connecte-toi à ton serveur pour voir le tien.",
                          systemImage: "wifi.slash")
                        .foregroundStyle(Palette.texteSecondaire)
                }
            } else if sansFoyer {
                Section {
                    Text("Tu ne fais partie d'aucun foyer.")
                        .foregroundStyle(Palette.texteSecondaire)
                }
            } else if let lu {
                contenu(lu)
            } else if erreur == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            LigneRefus(texte: erreur)
        }
        .navigationTitle(lu?.nom ?? "Le foyer")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, le foyer")
        .task { await charger() }
        .refreshable { await charger() }
        .overlay { if envoi { ProgressView().padding(20).carte(rayon: Rayon.controle) } }
        .sheet(isPresented: $invitation, onDismiss: { Task { await charger() } }) {
            NavigationStack { EcranInvitation() }.feuilleEnVerre()
        }
        // Le membre voyage avec la boîte : il est là quand on touche le bouton.
        .confirmationDialog("Retirer \(aRetirer?.nom ?? "") du foyer ?", isPresented: Binding {
            aRetirer != nil
        } set: { if !$0 { aRetirer = nil } }, titleVisibility: .visible, presenting: aRetirer) { membre in
            Button("Retirer", role: .destructive) {
                Task { await agir("DELETE", "foyer/membres/\(membre.id)", "\(membre.nom) ne fait plus partie du foyer") }
            }
        }
        .confirmationDialog("Passer l'administration à \(aPromouvoir?.nom ?? "") ?", isPresented: Binding {
            aPromouvoir != nil
        } set: { if !$0 { aPromouvoir = nil } }, titleVisibility: .visible, presenting: aPromouvoir) { membre in
            Button("Passer l'administration") { Task { await passer(membre) } }
        }
        .confirmationDialog("Quitter le foyer ?", isPresented: $quitter, titleVisibility: .visible) {
            Button("Quitter", role: .destructive) { Task { await partir() } }
        } message: {
            if lu?.membres.count == 1 { Text("Tu es seul : le foyer se ferme.") }
        }
    }

    @ViewBuilder
    private func contenu(_ lu: FoyerLu) -> some View {
        Section {
            ForEach(lu.membres) { membre in
                HStack(spacing: 12) {
                    Avatar(nom: membre.nom, couleur: membre.id == foyer.moi.id ? Categorie.travail.couleur : Categorie.chat.couleur,
                           taille: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(membre.id == foyer.moi.id ? "\(membre.nom) (toi)" : membre.nom)
                            .foregroundStyle(Palette.textePrincipal)
                        Text("@\(membre.pseudo)").font(.footnote).foregroundStyle(Palette.texteSecondaire)
                    }
                    Spacer()
                    if membre.administrateur { Puce("Admin", categorie: .ia) }
                }
                .swipeActions(edge: .trailing) {
                    if lu.jeSuisAdmin && membre.id != foyer.moi.id {
                        Button("Retirer", role: .destructive) { aRetirer = membre }
                        Button("Admin") { aPromouvoir = membre }.tint(Categorie.ia.couleur)
                    }
                }
                .contextMenu {
                    if lu.jeSuisAdmin && membre.id != foyer.moi.id {
                        Button("Lui passer l'administration", systemImage: "crown") { aPromouvoir = membre }
                        Button("Retirer du foyer", systemImage: "person.badge.minus", role: .destructive) { aRetirer = membre }
                    }
                }
            }
        } header: {
            Text("Membres")
        } footer: {
            if lu.jeSuisAdmin && lu.membres.count > 1 {
                Text("Glisse un membre vers la gauche, ou appuie longuement, pour lui passer l'administration ou le retirer.")
            }
        }

        if lu.jeSuisAdmin {
            Section {
                ForEach(lu.invitations) { invitation in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Invitation en attente").foregroundStyle(Palette.textePrincipal)
                            Text("Valable jusqu'au " + invitation.expireLe.formatted(
                                .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(enFrancais)))
                                .font(.footnote).foregroundStyle(Palette.texteSecondaire)
                        }
                        Spacer()
                        Button("Annuler") {
                            Task { await agir("DELETE", "foyer/invitations/\(invitation.id)", "Invitation annulée") }
                        }
                        .buttonStyle(.hal(.danger))
                    }
                }
                if lu.placesLibres > 0 {
                    Button { invitation = true } label: {
                        Label("Inviter quelqu'un", systemImage: "person.badge.plus")
                    }
                }
            } header: {
                Text("Inviter")
            } footer: {
                if lu.placesLibres == 0 { Text("Le foyer est complet.") }
            }

            Section {
                TextField("Nom du foyer", text: $nom)
                    .onSubmit { Task { await renommer() } }
                if nom != lu.nom, !nom.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Renommer") { Task { await renommer() } }
                }
            } header: {
                Text("Nom")
            }
        }

        Section {
            Picker("Ajouter des tâches", selection: droit(lu, \.ajoutTaches, cle: "ajout_taches")) {
                Text("Tout le monde").tag("tous")
                Text("L'administrateur").tag("admin")
            }
            Picker("Modifier et arrêter", selection: droit(lu, \.modifTaches, cle: "modif_taches")) {
                Text("Tout le monde").tag("tous")
                Text("L'administrateur").tag("admin")
            }
        } header: {
            Text("Droits sur les tâches")
        }
        .disabled(!lu.jeSuisAdmin)

        Section {
            Button("Quitter le foyer", role: .destructive) { quitter = true }
        }
    }

    /// Un réglage de droit : affiché tel que lu, envoyé dès qu'il change.
    private func droit(_ lu: FoyerLu, _ chemin: KeyPath<FoyerLu, String>, cle: String) -> Binding<String> {
        Binding {
            lu[keyPath: chemin]
        } set: { valeur in
            Task { await regler([cle: valeur], annonce: "Droits enregistrés") }
        }
    }

    private func charger() async {
        guard foyer.connecte else { return }
        do {
            let rendu: FoyerLu = try await foyer.demander("GET", "foyer")
            lu = rendu
            nom = rendu.nom
            sansFoyer = false
            erreur = nil
        } catch let refus as ErreurAPI where refus.code == "aucun_foyer" {
            sansFoyer = true
            lu = nil
        } catch {
            erreur = motifDe(error)
        }
    }

    private func regler(_ champs: [String: String], annonce: String) async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            let rendu: FoyerLu = try await foyer.demander("PATCH", "foyer",
                                                          corps: try? JSONSerialization.data(withJSONObject: champs))
            lu = rendu
            nom = rendu.nom
            annoncer(annonce)
            await foyer.charger()
        } catch {
            erreur = motifDe(error)
        }
    }

    private func renommer() async {
        let propre = nom.trimmingCharacters(in: .whitespaces)
        guard !propre.isEmpty, propre != lu?.nom else { return }
        await regler(["nom": propre], annonce: "Foyer renommé")
    }

    private func agir(_ methode: String, _ chemin: String, _ annonce: String) async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            try await foyer.agir(methode, chemin)
            annoncer(annonce)
            await charger()
        } catch {
            erreur = motifDe(error)
        }
    }

    private struct Promotion: Encodable { let idUtilisateur: Int }

    private func passer(_ membre: FoyerLu.MembreLu) async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            let rendu: FoyerLu = try await foyer.demander("POST", "foyer/administrateur",
                                                          corps: ClientAPI.corps(Promotion(idUtilisateur: membre.id)))
            lu = rendu
            annoncer("\(membre.nom) administre le foyer")
            await foyer.charger()
        } catch {
            erreur = motifDe(error)
        }
    }

    private func partir() async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            try await foyer.agir("POST", "foyer/quitter")
            annoncer("Tu as quitté le foyer")
            await charger()
        } catch {
            erreur = motifDe(error)
        }
    }
}

// MARK: - 5.16 Inviter dans le foyer

/// FOY-3 : un code et un lien, valables 48 heures et une seule fois. Le code
/// n'est montré qu'ici, à sa création : partager, copier, ou annuler.
struct EcranInvitation: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var creee: InvitationCreee?
    @State private var envoi = false
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            if let creee {
                Section {
                    Text(creee.code)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.textePrincipal)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                        .accessibilityLabel("Code d'invitation \(creee.code.map { String($0) }.joined(separator: " "))")
                } header: {
                    Text("Le code")
                } footer: {
                    Text("Valable jusqu'au \(creee.expireLe.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(enFrancais))), une seule fois.")
                }
                Section {
                    if let lien = creee.lien.flatMap(URL.init(string:)) {
                        ShareLink(item: lien, subject: Text("Rejoins le foyer dans HAL"), message: Text(texteDuPartage(creee))) {
                            Label("Partager le lien", systemImage: "square.and.arrow.up")
                        }
                        Button("Copier le lien", systemImage: "link") {
                            UIPasteboard.general.string = lien.absoluteString
                            annoncer("Lien copié")
                        }
                    }
                    Button("Copier le code", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = creee.code
                        annoncer("Code copié")
                    }
                }
                Section {
                    Button("Annuler l'invitation", role: .destructive) { Task { await annuler(creee) } }
                        .disabled(envoi)
                }
            } else {
                LigneRefus(texte: erreur)
                Section {
                    Button {
                        Task { await creer() }
                    } label: {
                        HStack { Spacer(); if envoi { ProgressView() } else { Text("Créer l'invitation").bold() }; Spacer() }
                    }
                    .disabled(envoi || !foyer.connecte)
                }
            }
            if creee != nil { LigneRefus(texte: erreur) }
        }
        .navigationTitle("Inviter dans le foyer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { fermer() }
            }
        }
    }

    private func texteDuPartage(_ invitation: InvitationCreee) -> String {
        "Rejoins notre foyer dans HAL : \(invitation.lien ?? "") — ou dans l'appli, « J'ai une invitation », le code \(invitation.code). Valable 48 heures."
    }

    private func creer() async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            creee = try await foyer.demander("POST", "foyer/invitations")
        } catch {
            erreur = motifDe(error)
        }
    }

    private func annuler(_ invitation: InvitationCreee) async {
        envoi = true
        defer { envoi = false }
        do {
            try await foyer.agir("DELETE", "foyer/invitations/\(invitation.id)")
            annoncer("Invitation annulée")
            fermer()
        } catch {
            erreur = motifDe(error)
        }
    }
}

// MARK: - 5.11 Notifications et heures

/// Mes heures (bilan, relance, récap), ce qui prévient, et le silence (NOT-14,
/// NOT-15). L'accord d'iOS se donne ici s'il a été passé au premier lancement.
struct EcranNotifications: View {
    @Environment(Foyer.self) private var foyer
    @Environment(Notifications.self) private var notifications
    @Environment(\.annoncer) private var annoncer
    @Environment(\.openURL) private var ouvrir
    @State private var lues: HeuresLues?
    @State private var heures: HeuresLues?
    @State private var envoi = false
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            Section {
                switch notifications.etat {
                case .autorisees:
                    LabeledContent("Sur cet iPhone", value: notifications.enregistre ? "Activées" : "Activées · en attente du serveur")
                case .aDemander:
                    Button("Activer les notifications") { Task { await notifications.demander() } }
                case .refusees:
                    LabeledContent("Sur cet iPhone", value: "Refusées")
                    Button("Ouvrir les réglages d'iOS") {
                        if let lien = URL(string: UIApplication.openNotificationSettingsURLString) { ouvrir(lien) }
                    }
                }
            } footer: {
                if notifications.etat == .refusees {
                    Text("iOS seul peut les rallumer : Réglages, Notifications, HAL.")
                }
            }

            if !foyer.connecte {
                Section {
                    Label("Connecte-toi à ton serveur pour régler tes heures.", systemImage: "wifi.slash")
                        .foregroundStyle(Palette.texteSecondaire)
                }
            } else if let heures {
                Section {
                    selecteur("Bilan du matin", \.bilan, heures, icone: "bell", couleur: Categorie.menage.couleur)
                    selecteur("Relance du soir", \.relance, heures, icone: "checklist", couleur: Categorie.sport.couleur)
                    selecteur("Récap de HAL", \.recap, heures, icone: "sparkle", couleur: Categorie.ia.couleur)
                } header: {
                    Text("Mes heures")
                }
                Section {
                    HStack(spacing: 10) {
                        tuile("De", \.silenceDebut, heures)
                        tuile("À", \.silenceFin, heures)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Silence de nuit")
                }
                LigneRefus(texte: erreur)
                if heures != lues {
                    Section {
                        Button {
                            Task { await enregistrer() }
                        } label: {
                            HStack { Spacer(); if envoi { ProgressView() } else { Text("Enregistrer").bold() }; Spacer() }
                        }
                        .disabled(envoi)
                    }
                }
            } else {
                LigneRefus(texte: erreur)
                if erreur == nil { Section { ProgressView().frame(maxWidth: .infinity) } }
            }

            Section("Ce qui te prévient") {
                ligne("sun.max", "Le bilan du matin", "Ta journée, et ce qui est en retard")
                ligne("moon", "La relance du soir", "« C'est fait ? » pour ce qui reste")
                ligne("sparkle", "HAL", "Le récap du soir, ses ajustements, ses réponses panneau fermé")
                ligne("arrow.triangle.2.circlepath", "Les changements", "Chaque changement qui te touche")
                ligne("checkmark.circle", "Le foyer", "Une de tes tâches faite par un autre")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, notifications et heures")
        .task {
            await notifications.relire()
            await charger()
        }
    }

    private func ligne(_ icone: String, _ titre: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(titre).foregroundStyle(Palette.textePrincipal)
                Text(detail).font(.footnote).foregroundStyle(Palette.texteSecondaire)
            }
        } icon: {
            Image(systemName: icone).foregroundStyle(Categorie.ia.couleur)
        }
    }

    private func lien(_ chemin: WritableKeyPath<HeuresLues, String>, _ actuelles: HeuresLues) -> Binding<Date> {
        Binding {
            Heure.date(actuelles[keyPath: chemin])
        } set: { date in
            heures?[keyPath: chemin] = Heure.texte(date)
        }
    }

    private func selecteur(_ titre: String, _ chemin: WritableKeyPath<HeuresLues, String>,
                           _ actuelles: HeuresLues, icone: String, couleur: Color) -> some View {
        HStack(spacing: 12) {
            Pastille(icone: icone, couleur: couleur)
            DatePicker(titre, selection: lien(chemin, actuelles), displayedComponents: .hourAndMinute)
                .environment(\.locale, enFrancais)
        }
    }

    /// 5.11 : le début et la fin du silence, en deux tuiles.
    private func tuile(_ titre: String, _ chemin: WritableKeyPath<HeuresLues, String>,
                       _ actuelles: HeuresLues) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            DatePicker(titre, selection: lien(chemin, actuelles), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .environment(\.locale, enFrancais)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func charger() async {
        guard foyer.connecte else { return }
        do {
            let rendues: HeuresLues = try await foyer.demander("GET", "moi/heures")
            lues = rendues
            heures = rendues
            erreur = nil
        } catch {
            erreur = motifDe(error)
        }
    }

    private func enregistrer() async {
        guard let heures else { return }
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            let rendues: HeuresLues = try await foyer.demander("PATCH", "moi/heures", corps: ClientAPI.corps(heures))
            lues = rendues
            self.heures = rendues
            annoncer("Heures enregistrées : elles valent dès demain")
        } catch {
            erreur = motifDe(error)
        }
    }
}

// MARK: - 5.13 Serveur et connexion

/// À quel serveur on est connecté et dans quel état, changer son mot de passe,
/// se déconnecter (CNX-2, CNX-6). En démonstration, se connecter.
struct EcranServeur: View {
    @Environment(Session.self) private var session
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(Notifications.self) private var notifications
    @Environment(\.annoncer) private var annoncer
    @State private var nouveau = ""
    @State private var confirmation = ""
    @State private var enCours = false
    @State private var essai = false
    @State private var erreur: String?
    @State private var confirmer = false

    var body: some View {
        FormulaireVerre {
            if let pseudo = session.pseudo {
                Section {
                    LabeledContent("Pseudo", value: pseudo)
                    LabeledContent("Serveur", value: session.adresse?.host() ?? "")
                    LabeledContent("État", value: etat)
                    if let misAJour = foyer.misAJour {
                        LabeledContent("Données", value: Self.quand(misAJour))
                    }
                    if !file.enAttente.isEmpty {
                        LabeledContent("En attente d'envoi", value: "\(file.enAttente.count)")
                    }
                    Button {
                        Task { await tester() }
                    } label: {
                        HStack { Text("Tester la connexion"); Spacer(); if essai { ProgressView() } }
                    }
                    .disabled(essai)
                } header: {
                    Text("Connexion")
                }
                Section {
                    SecureField("Nouveau mot de passe", text: $nouveau)
                        .textContentType(.newPassword)
                    SecureField("Encore une fois", text: $confirmation)
                        .textContentType(.newPassword)
                    Button("Changer le mot de passe") { Task { await changer() } }
                        .disabled(nouveau.count < 10 || nouveau != confirmation || enCours)
                } header: {
                    Text("Mot de passe")
                } footer: {
                    Text("Au moins dix caractères.")
                }
                if let erreur {
                    Section { Label(erreur, systemImage: "exclamationmark.circle").foregroundStyle(Categorie.alerte.couleur) }
                }
                Section {
                    Button("Se déconnecter", role: .destructive) { confirmer = true }
                        .frame(maxWidth: .infinity)
                } footer: {
                    if !file.enAttente.isEmpty {
                        Text("\(file.enAttente.count) envoi(s) en attente seront perdus.")
                    }
                }
            } else {
                Section {
                    Text("L'appli tourne sur des données fictives.")
                    Button("Se connecter à un serveur") { session.deconnecter() }
                }
            }
        }
        .navigationTitle("Serveur et connexion")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Se déconnecter ?", isPresented: $confirmer, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) { Task { await deconnecter() } }
        }
    }

    private var etat: String {
        if foyer.cleRefusee { return "Clé refusée" }
        if !file.reseauDisponible || foyer.injoignable { return "Injoignable" }
        if foyer.erreur != nil { return "Pas à jour" }
        return "Joignable"
    }

    /// « à 14:32 », « hier à 18:05 », « le 12 oct. à 9:10 ».
    static func quand(_ date: Date) -> String {
        let heure = date.formatted(date: .omitted, time: .shortened)
        let calendrier = Calendar.current
        if calendrier.isDateInToday(date) { return "à \(heure)" }
        if calendrier.isDateInYesterday(date) { return "hier à \(heure)" }
        return "le \(date.formatted(.dateTime.day().month(.abbreviated).locale(enFrancais))) à \(heure)"
    }

    private func tester() async {
        essai = true
        defer { essai = false }
        await file.vider()
        await foyer.charger()
        annoncer(foyer.erreur == nil ? "Serveur joignable" : (foyer.erreur ?? "Injoignable"))
    }

    /// CNX-6 : l'iPhone quitte la liste des notifications avant que la clé ne s'efface.
    private func deconnecter() async {
        await notifications.oublier()
        file.vider(sansEnvoyer: true)
        session.deconnecter()
    }

    private struct Demande: Encodable { let motDePasse: String }

    private func changer() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        do {
            try await foyer.agir("PUT", "mot-de-passe", corps: ClientAPI.corps(Demande(motDePasse: nouveau)))
            nouveau = ""
            confirmation = ""
            annoncer("Mot de passe changé")
        } catch {
            erreur = motifDe(error)
        }
    }
}
