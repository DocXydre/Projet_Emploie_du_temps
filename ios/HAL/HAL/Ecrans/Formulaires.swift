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

/// Un formulaire d'iOS en Liquid Glass : pas de fond opaque, des groupes en
/// voile clair posés sur le verre de la feuille ou sur la photo de fond.
struct FormulaireVerre<Contenu: View>: View {
    @ViewBuilder var contenu: Contenu

    var body: some View {
        Form {
            Group { contenu }
                .listRowBackground(FondDeLigne())
        }
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
    }
}

/// Le fond d'une ligne de formulaire : le même verre dépoli que les cartes, pour
/// que le texte reste lisible sur une photo claire.
struct FondDeLigne: View {
    @Environment(\.verre) private var verre

    var body: some View {
        if let glass = verre.glass {
            Rectangle().fill(.clear).glassEffect(glass, in: .rect)
        } else {
            Rectangle().fill(.ultraThinMaterial).overlay(Palette.verreTeinte)
        }
    }
}

extension View {
    /// Une feuille en Liquid Glass même déployée en entier : iOS la rend
    /// opaque à pleine hauteur, on lui redonne son verre.
    func feuilleEnVerre() -> some View {
        presentationBackground {
            Rectangle().fill(.clear).glassEffect(.regular, in: .rect)
        }
    }
}

extension EnvironmentValues {
    /// Ferme toute la feuille du « + », pas seulement le formulaire ouvert dedans.
    @Entry var fermerFeuille: ActionFermer? = nil
    /// Ferme la vue agrandie d'un widget (WID-5) : la coquille montre alors son « × ».
    @Entry var fermerAgrandi: ActionFermer? = nil
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

    /// Le grand bouton accent de la maquette, posé sous le formulaire, sans fond de ligne.
    var body: some View {
        Section {
            Button(action: action) {
                HStack {
                    if enCours { ProgressView() }
                    Text(titre)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
            .disabled(!actif || enCours)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
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
        FormulaireVerre {
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
        FormulaireVerre {
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
    /// Pour qui : un membre, ou tout le foyer (nil).
    @State private var pour: Int?
    @State private var pourTous = false
    @State private var enCours = false
    @State private var erreur: String?

    /// 1.6 : un créneau posé à la main (COL-13). Le moteur n'y place rien.
    var body: some View {
        FormulaireVerre {
            Section("Titre") {
                TextField("Rendez-vous banque", text: $libelle)
                TextField("Lieu (facultatif)", text: $lieu)
            }
            Section {
                DatePicker("Jour", selection: $debut, displayedComponents: .date)
                DatePicker("De", selection: $debut, displayedComponents: .hourAndMinute)
                DatePicker("À", selection: $fin, in: debut..., displayedComponents: .hourAndMinute)
            } footer: {
                Text("Le moteur ne place rien sur ce créneau, et déplace ce qui y était.")
            }
            .environment(\.locale, Locale(identifier: "fr_FR"))
            if foyer.membres.count > 1 {
                Section("Pour qui") {
                    HStack(spacing: 8) {
                        PuceChoix(texte: "Moi", choisie: !pourTous && (pour ?? foyer.moi.id) == foyer.moi.id) {
                            pourTous = false
                            pour = foyer.moi.id
                        }
                        ForEach(foyer.membres.filter { $0 != foyer.moi }) { membre in
                            PuceChoix(texte: membre.nom, choisie: !pourTous && pour == membre.id) {
                                pourTous = false
                                pour = membre.id
                            }
                        }
                        PuceChoix(texte: "Les deux", choisie: pourTous) { pourTous = true }
                    }
                }
            }
            LigneErreur(texte: erreur)
            BoutonEnvoi(titre: "Ajouter",
                        actif: !libelle.trimmingCharacters(in: .whitespaces).isEmpty && fin > debut,
                        enCours: enCours) { Task { await envoyer() } }
        }
        .navigationTitle("Nouveau créneau")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: debut) { ancien, nouveau in
            // Changer le jour ou l'heure de début emporte la fin avec, à durée égale.
            let duree = max(900, fin.timeIntervalSince(ancien))
            fin = nouveau.addingTimeInterval(duree)
        }
    }

    private struct Demande: Encodable {
        let idUtilisateur: Int?
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
        let pourQui: [Int?] = pourTous ? foyer.membres.map(\.id) : [pour]
        do {
            for (rang, qui) in pourQui.enumerated() {
                // Le placement ne repart qu'une fois, avec le dernier créneau.
                let replacer = rang == pourQui.count - 1
                try await foyer.agir("POST", "occupations?replacer=\(replacer)", corps: ClientAPI.corps(Demande(
                    idUtilisateur: qui, type: "autre", libelle: libelle.trimmingCharacters(in: .whitespaces),
                    debut: debut, fin: fin, lieu: lieu.isEmpty ? nil : lieu)))
            }
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
        FormulaireVerre {
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
        FormulaireVerre {
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
                    Button("Arrêter le mode allégé") { Task { await arreter() } }
                        .foregroundStyle(Palette.texteSecondaire)
                        .frame(maxWidth: .infinity)
                }
            }
        }
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
    @Environment(\.openURL) private var ouvrirLien
    @Environment(\.annoncer) private var annoncer

    private enum Sens: Hashable { case aller, retour }

    @State private var rang = 1
    @State private var sens = Sens.aller
    @State private var allers: [Train]?
    @State private var aller: Train?
    @State private var retours: [Train]?
    @State private var retour: Train?
    @State private var enCours = false
    @State private var erreur: String?

    /// 1.13 : les départs conseillés selon le planning, l'aller puis le retour ;
    /// les retenir pose l'absence. L'achat se fait dans l'app SNCF (TRJ-8).
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Espace.gouttiere) {
                    ZStack {
                        Text("Week-end à \(proposition.lieu)").texte(.titreWidget)
                            .foregroundStyle(Palette.textePrincipal).surLaPhoto()
                        HStack {
                            BoutonRond("chevron.left", libelle: "Fermer") { fermer() }
                            Spacer()
                            Menu {
                                Button("Créneau suivant") { rang += 1 }
                                if aller != nil {
                                    Button("Retenir sans retour") { Task { await retenir(retour: nil) } }
                                }
                                Button("Pas ce week-end", role: .destructive) { Task { await decliner() } }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Palette.textePrincipal)
                                    .frame(width: 36, height: 36)
                                    .verreControle(Circle())
                            }
                            .accessibilityLabel("Plus")
                        }
                    }
                    .frame(height: 44)
                    HStack(alignment: .top, spacing: 10) {
                        Orbe(etat: .repos, taille: 22)
                        Text("Libre du \(Self.jour(proposition.debut)) au \(Self.jour(proposition.fin)). Voici les trains qui tiennent dans le planning.")
                            .texte(.corps).foregroundStyle(Palette.textePrincipal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Espace.interne)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: Rayon.controle)
                    Segmente(choix: [(Sens.aller, "Aller · \(Self.jourCourt(proposition.debut))"),
                                     (Sens.retour, "Retour · \(Self.jourCourt(proposition.fin))")],
                             selection: $sens)
                    if let erreur {
                        Label(erreur, systemImage: "exclamationmark.circle")
                            .texte(.corps).foregroundStyle(Categorie.alerte.couleur)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    liste(sens == .aller ? allers : retours, choisi: sens == .aller ? aller : retour)
                    Button(boutonPrincipal) { Task { await agir() } }
                        .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                        .disabled(sens == .aller ? aller == nil : retour == nil)
                    Button("Ouvrir SNCF Connect") {
                        if let lien = URL(string: "https://www.sncf-connect.com") { ouvrirLien(lien) }
                    }
                    .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
                }
                .padding(.horizontal, Espace.marge)
                .padding(.bottom, 40)
            }
            .ecranHAL()
            .task(id: rang) { await chercherAllers() }
            .onChange(of: sens) { _, nouveau in
                if nouveau == .retour, retours == nil, let aller { Task { await chercherRetours(aller) } }
            }
        }
        .disabled(enCours)
        .feuilleEnVerre()
    }

    private var boutonPrincipal: String {
        switch sens {
        case .aller: aller.map { "Choisir le \(Self.heureSeule($0.depart)), puis le retour" } ?? "Choisis un aller"
        case .retour: retour == nil ? "Choisis un retour" : "Ajouter les trains au planning"
        }
    }

    private func agir() async {
        switch sens {
        case .aller:
            sens = .retour
        case .retour:
            await retenir(retour: retour)
        }
    }

    @ViewBuilder
    private func liste(_ trains: [Train]?, choisi: Train?) -> some View {
        if let trains {
            if trains.isEmpty {
                Text(sens == .aller ? "Aucun train sur ce créneau." : "Aucun retour trouvé.")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .carte(rayon: Rayon.controle)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(trains.enumerated()), id: \.element.id) { rangTrain, train in
                        Button {
                            withAnimation(.snappy) {
                                if sens == .aller {
                                    aller = train
                                    retours = nil
                                    retour = nil
                                } else {
                                    retour = train
                                }
                            }
                        } label: {
                            ligne(train, conseille: rangTrain == 0, choisi: train == choisi)
                        }
                        .buttonStyle(.plain)
                        if rangTrain < trains.count - 1 { Divider().overlay(Palette.verreBord) }
                    }
                }
                .carte(rayon: Rayon.controle)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    /// « 09:12 → 10:36 Conseillé », puis « 1 h 24 · TER · direct ».
    private func ligne(_ train: Train, conseille: Bool, choisi: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("\(Self.heureSeule(train.depart)) → \(Self.heureSeule(train.arrivee))")
                        .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    if conseille { Puce("Conseillé", categorie: .sport) }
                }
                Text(detail(train)).texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: choisi ? "checkmark.circle.fill" : "chevron.right")
                .font(.system(size: choisi ? 20 : 13, weight: .semibold))
                .foregroundStyle(choisi ? Categorie.sport.couleur : Palette.texteTertiaire)
        }
        .padding(.horizontal, Espace.interne)
        .padding(.vertical, 12)
        .background(choisi ? Palette.verreTeinte : .clear)
        .contentShape(Rectangle())
    }

    private func detail(_ train: Train) -> String {
        var morceaux = [EnFrancais.duree(minutes: Int(train.arrivee.timeIntervalSince(train.depart) / 60))]
        if let resume = train.resume, !resume.isEmpty { morceaux.append(resume) }
        let correspondances = train.correspondances ?? 0
        morceaux.append(correspondances == 0 ? "direct"
                        : "\(correspondances) changement\(correspondances > 1 ? "s" : "")")
        return morceaux.joined(separator: " · ")
    }

    static func jourCourt(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }

    static func heureSeule(_ date: Date) -> String { EnFrancais.heure(date) }

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

    private func chercherRetours(_ train: Train) async {
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
