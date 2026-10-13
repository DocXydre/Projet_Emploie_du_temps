import SwiftUI

// Les formulaires du « + » (APP-9) : tout se fait à la main, sans HAL. Ce sont
// des Form d'iOS, sans fond à nous : la feuille reste en Liquid Glass.

/// Ce qu'un formulaire montre quand le serveur refuse : son motif, tel quel.
private struct LigneErreur: View {
    let texte: String?

    var body: some View {
        if let texte {
            Section {
                Label(texte, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Categorie.alerte.couleur)
            }
        }
    }
}

extension EnvironmentValues {
    /// Ferme toute la feuille du « + », pas seulement le formulaire ouvert dedans.
    @Entry var fermerFeuille: ActionFermer? = nil
}

/// Une fermeture rangée dans une structure : SwiftUI ne compare pas les
/// fermetures, et en garder une nue dans l'environnement redessinerait tout.
struct ActionFermer {
    let fermer: () -> Void
}

private func motif(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

/// Un bouton « Enregistrer » qui montre qu'il travaille.
private struct BoutonEnvoi: View {
    let titre: String
    let actif: Bool
    let enCours: Bool
    var action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                HStack {
                    Spacer()
                    if enCours { ProgressView() } else { Text(titre).bold() }
                    Spacer()
                }
            }
            .disabled(!actif || enCours)
        }
    }
}

// MARK: - Ajouter une tâche                                         (TAC-20, FOY-6)

struct FormulaireTache: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer

    private static let familles: [(String, String)] = [
        ("menage", "Ménage"), ("linge", "Linge"), ("vaisselle", "Vaisselle"), ("animal", "Chat"),
    ]

    @State private var libelle = ""
    @State private var famille = "menage"
    @State private var duree = 15
    @State private var tousLes = 7
    @State private var pourQui: Int? = nil
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        Form {
            if !foyer.droits.ajouter {
                Section {
                    Label("L'administrateur du foyer garde l'ajout des tâches pour lui.",
                          systemImage: "lock")
                }
            }
            Section("La tâche") {
                TextField("Arroser les plantes", text: $libelle)
                Picker("Famille", selection: $famille) {
                    ForEach(Self.familles.indices, id: \.self) { rang in
                        Text(Self.familles[rang].1).tag(Self.familles[rang].0)
                    }
                }
                Stepper("Durée : \(duree) min", value: $duree, in: 5...180, step: 5)
            }
            Section {
                Stepper(tousLes == 1 ? "Tous les jours" : "Tous les \(tousLes) jours",
                        value: $tousLes, in: 1...60)
                Picker("Pour qui", selection: $pourQui) {
                    Text("Le moteur répartit").tag(Int?.none)
                    ForEach(foyer.membres) { Text($0.nom).tag(Int?.some($0.id)) }
                }
            } header: {
                Text("Quand")
            } footer: {
                Text("Le moteur la place dans un creux, à un jour près, et la répartit selon le temps passé par chacun.")
            }
            LigneErreur(texte: erreur)
            BoutonEnvoi(titre: "Ajouter", actif: !libelle.trimmingCharacters(in: .whitespaces).isEmpty
                        && foyer.droits.ajouter, enCours: enCours) { Task { await envoyer() } }
        }
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Ajouter une tâche")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Demande: Encodable {
        let code: String
        let libelle: String
        let categorie: String
        let dureeMinutes: Int
        let periodiciteMinJours: Int
        let periodiciteMaxJours: Int
        let idUtilisateurDefaut: Int?
    }

    /// « Arroser les plantes » devient « ARROSER_LES_PLANTES_4821 » : unique, et lisible au journal.
    private var code: String {
        let sansAccent = libelle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "fr_FR"))
        let lettres = sansAccent.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let racine = String(lettres).split(separator: "_").joined(separator: "_").prefix(24)
        return "\(racine.isEmpty ? "TACHE" : String(racine))_\(Int.random(in: 1000...9999))"
    }

    private func envoyer() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        let propre = libelle.trimmingCharacters(in: .whitespaces)
        do {
            try await foyer.agir("POST", "taches?replacer=true", corps: ClientAPI.corps(Demande(
                code: code, libelle: propre, categorie: famille, dureeMinutes: duree,
                periodiciteMinJours: max(1, tousLes - (tousLes > 2 ? 1 : 0)),
                periodiciteMaxJours: tousLes + (tousLes > 2 ? 1 : 0),
                idUtilisateurDefaut: pourQui)))
            annoncer("« \(propre) » ajoutée")
            (fermerFeuille?.fermer ?? { fermer() })()
        } catch {
            erreur = motif(error)
        }
    }
}

// MARK: - C'est fait                                                     (EXE-15)

struct FormulaireFaite: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer
    @State private var taches: [TacheRecurrente] = []
    @State private var quand = Date.now
    @State private var enCours: Int?
    @State private var erreur: String?

    var body: some View {
        Form {
            Section {
                DatePicker("Quand", selection: $quand, in: ...Date.now)
            } footer: {
                Text("Prévue ou non : la suivante repart de ce moment-là.")
            }
            LigneErreur(texte: erreur)
            Section("Ce que tu as fait") {
                if taches.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(taches) { tache in
                    Button {
                        Task { await declarer(tache) }
                    } label: {
                        HStack {
                            Text(tache.libelle).foregroundStyle(Palette.textePrincipal)
                            Spacer()
                            if enCours == tache.id { ProgressView() }
                        }
                    }
                    .disabled(enCours != nil)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("C'est fait")
        .navigationBarTitleDisplayMode(.inline)
        .task { await lire() }
    }

    private func lire() async {
        do {
            let toutes: [TacheRecurrente] = try await foyer.demander("GET", "taches")
            taches = toutes.filter { $0.categorie != "sport" }
        } catch {
            erreur = motif(error)
        }
    }

    private struct Demande: Encodable {
        let codeTache: String
        let quand: Date
    }

    private func declarer(_ tache: TacheRecurrente) async {
        enCours = tache.id
        erreur = nil
        defer { enCours = nil }
        do {
            try await foyer.agir("POST", "occurrences/faite",
                                 corps: ClientAPI.corps(Demande(codeTache: tache.code, quand: quand)))
            annoncer("« \(tache.libelle) » faite")
            (fermerFeuille?.fermer ?? { fermer() })()
        } catch {
            erreur = motif(error)
        }
    }
}

// MARK: - Poser un créneau                                               (COL-6)

struct FormulaireCreneau: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer
    @State private var libelle = ""
    @State private var lieu = ""
    @State private var debut = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    @State private var fin = Calendar.current.date(byAdding: .hour, value: 2, to: .now) ?? .now
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        Form {
            Section {
                TextField("Rendez-vous chez le dentiste", text: $libelle)
                TextField("Lieu (facultatif)", text: $lieu)
            }
            Section {
                DatePicker("Début", selection: $debut)
                DatePicker("Fin", selection: $fin, in: debut...)
            } footer: {
                Text("Le moteur ne place rien sur ce créneau, et déplace ce qui y était.")
            }
            LigneErreur(texte: erreur)
            BoutonEnvoi(titre: "Poser le créneau",
                        actif: !libelle.trimmingCharacters(in: .whitespaces).isEmpty && fin > debut,
                        enCours: enCours) { Task { await envoyer() } }
        }
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Poser un créneau")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: debut) { _, nouveau in
            if fin <= nouveau { fin = nouveau.addingTimeInterval(3600) }
        }
    }

    private struct Demande: Encodable {
        let type: String
        let libelle: String
        let debut: Date
        let fin: Date
        let lieu: String?
    }

    private func envoyer() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        do {
            try await foyer.agir("POST", "occupations?replacer=true", corps: ClientAPI.corps(Demande(
                type: "autre", libelle: libelle.trimmingCharacters(in: .whitespaces),
                debut: debut, fin: fin, lieu: lieu.isEmpty ? nil : lieu)))
            annoncer("Créneau posé")
            (fermerFeuille?.fermer ?? { fermer() })()
        } catch {
            erreur = motif(error)
        }
    }
}

// MARK: - Une absence                                                     (ABS)

struct FormulaireAbsence: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer
    @State private var lieu = ""
    @State private var debut = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
    @State private var fin = Calendar.current.startOfDay(for: .now.addingTimeInterval(3 * 86_400))
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        Form {
            if !foyer.mesAbsences.isEmpty {
                Section("Déjà prévues") {
                    ForEach(foyer.mesAbsences) { absence in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(absence.lieu ?? "Absence").foregroundStyle(Palette.textePrincipal)
                            Text("\(Self.moment(absence.debut)) → \(Self.moment(absence.fin))")
                                .font(.footnote).foregroundStyle(Palette.texteSecondaire)
                        }
                        .swipeActions {
                            Button("Supprimer", role: .destructive) {
                                Task { await supprimer(absence) }
                            }
                        }
                    }
                }
            }
            Section {
                TextField("Lieu (facultatif)", text: $lieu)
                DatePicker("Départ", selection: $debut)
                DatePicker("Retour", selection: $fin, in: debut...)
            } header: {
                Text("Nouvelle absence")
            } footer: {
                Text("Tes tâches de ces jours-là passent aux autres, et reviennent à ton retour.")
            }
            LigneErreur(texte: erreur)
            BoutonEnvoi(titre: "Déclarer l'absence", actif: fin > debut, enCours: enCours) {
                Task { await envoyer() }
            }
        }
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Une absence")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
            .locale(Locale(identifier: "fr_FR")))
    }

    private struct Demande: Encodable {
        let debut: Date
        let fin: Date
        let lieu: String?
    }

    private func envoyer() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        do {
            try await foyer.agir("POST", "absences?replacer=true", corps: ClientAPI.corps(Demande(
                debut: debut, fin: fin, lieu: lieu.isEmpty ? nil : lieu)))
            annoncer("Absence déclarée")
            (fermerFeuille?.fermer ?? { fermer() })()
        } catch {
            erreur = motif(error)
        }
    }

    private func supprimer(_ absence: Absence) async {
        do {
            try await foyer.agir("DELETE", "absences/\(absence.id)?replacer=true")
            annoncer("Absence supprimée")
        } catch {
            erreur = motif(error)
        }
    }
}

// MARK: - Mode allégé                                                   (PLA-16)

struct FormulaireAllege: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer
    @State private var etat: EtatAllegement?
    @State private var jours = 3
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        Form {
            Section {
                if let etat {
                    Text(etat.texte).foregroundStyle(Palette.textePrincipal)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            Section {
                Stepper(jours == 1 ? "Aujourd'hui seulement" : "\(jours) jours", value: $jours, in: 1...14)
            } header: {
                Text(etat?.enCours == true ? "Changer la durée, à partir d'aujourd'hui" : "Pour combien de temps")
            } footer: {
                Text("Tu fais un quart des tâches partagées, l'autre trois quarts. Ce qui t'est réservé reste à toi.")
            }
            LigneErreur(texte: erreur)
            BoutonEnvoi(titre: etat?.enCours == true ? "Changer" : "Passer en mode allégé",
                        actif: etat != nil, enCours: enCours) { Task { await activer() } }
            if etat?.enCours == true {
                Section {
                    Button("Arrêter le mode allégé", role: .destructive) { Task { await arreter() } }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Mode allégé")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { etat = try await foyer.demander("GET", "allegement") } catch { erreur = motif(error) }
        }
    }

    private struct Demande: Encodable { let jours: Int }

    private func activer() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        do {
            let reponse: EtatAllegement = try await foyer.demander(
                "PUT", "allegement", corps: ClientAPI.corps(Demande(jours: jours)))
            etat = reponse
            await foyer.charger()
            annoncer("Mode allégé pour \(jours == 1 ? "aujourd'hui" : "\(jours) jours")")
            (fermerFeuille?.fermer ?? { fermer() })()
        } catch {
            erreur = motif(error)
        }
    }

    private func arreter() async {
        do {
            try await foyer.agir("DELETE", "allegement")
            annoncer("Mode allégé arrêté")
            (fermerFeuille?.fermer ?? { fermer() })()
        } catch {
            erreur = motif(error)
        }
    }
}

// MARK: - Les trains d'un week-end                                   (TRJ, PRO)

struct EcranTrains: View {
    let proposition: Proposition
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer

    @State private var rang = 1
    @State private var allers: [Train]?
    @State private var aller: Train?
    @State private var retours: [Train]?
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Un week-end à \(proposition.lieu), du \(Self.jour(proposition.debut)) au \(Self.jour(proposition.fin)).")
                        .foregroundStyle(Palette.textePrincipal)
                }
                LigneErreur(texte: erreur)
                if let aller {
                    Section("Aller retenu") { ligne(aller, choisi: true) }
                    Section("Retour") {
                        if let retours {
                            if retours.isEmpty { Text("Aucun retour trouvé.").foregroundStyle(Palette.texteSecondaire) }
                            ForEach(retours) { train in
                                Button { Task { await retenir(retour: train) } } label: { ligne(train, choisi: false) }
                            }
                            Button("Sans retour pour l'instant") { Task { await retenir(retour: nil) } }
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    Section {
                        if let allers {
                            if allers.isEmpty { Text("Aucun train sur ce créneau.").foregroundStyle(Palette.texteSecondaire) }
                            ForEach(allers) { train in
                                Button { Task { await choisirAller(train) } } label: { ligne(train, choisi: false) }
                            }
                            Button("Créneau suivant") { rang += 1 }
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    } header: {
                        Text("Aller")
                    } footer: {
                        Text("Le premier train qu'on peut attraper après le dernier cours.")
                    }
                }
                Section {
                    Button("Non merci", role: .destructive) { Task { await decliner() } }
                        .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Partir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { fermer() } }
            }
            .task(id: rang) { await chercherAllers() }
        }
        .disabled(enCours)
    }

    private func ligne(_ train: Train, choisi: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.heure(train.depart)) → \(Self.heure(train.arrivee))")
                    .foregroundStyle(Palette.textePrincipal)
                Text(train.resume ?? Self.jour(train.depart))
                    .font(.footnote).foregroundStyle(Palette.texteSecondaire)
            }
            Spacer()
            if choisi { Image(systemName: "checkmark").foregroundStyle(Categorie.sport.couleur) }
        }
    }

    static func jour(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }

    static func heure(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR")))
    }

    private func chercherAllers() async {
        allers = nil
        erreur = nil
        do {
            let choix: ChoixDeTrains = try await foyer.demander("POST", "trajets/aller?rang=\(rang)")
            allers = choix.trajets
        } catch {
            allers = []
            erreur = motif(error)
        }
    }

    private func choisirAller(_ train: Train) async {
        aller = train
        retours = nil
        do {
            let choix: ChoixDeTrains = try await foyer.demander("POST", "trajets/retour?aller=\(train.id)")
            retours = choix.trajets
        } catch {
            retours = []
            erreur = motif(error)
        }
    }

    private struct Retenue: Encodable {
        let idAller: Int
        let idRetour: Int?
    }

    private func retenir(retour: Train?) async {
        guard let aller else { return }
        enCours = true
        defer { enCours = false }
        do {
            try await foyer.agir("POST", "trajets/retenir",
                                 corps: ClientAPI.corps(Retenue(idAller: aller.id, idRetour: retour?.id)))
            annoncer("Trains retenus : ton absence est posée")
            (fermerFeuille?.fermer ?? { fermer() })()
        } catch {
            erreur = motif(error)
        }
    }

    private func decliner() async {
        do {
            try await foyer.agir("DELETE", "trajets/propositions/\(proposition.id)")
            annoncer("Week-end écarté")
            (fermerFeuille?.fermer ?? { fermer() })()
        } catch {
            erreur = motif(error)
        }
    }
}
