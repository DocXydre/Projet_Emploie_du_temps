import SwiftUI

// Les tâches du foyer, à la main et sans HAL (APP-7) : en créer une pour
// aujourd'hui, entre deux dates, à une heure ou après une autre (TAC-20 à
// TAC-24) ; les ranger dans des types que le foyer colore (TAC-25, TAC-26) ; les
// relier entre elles (TAC-27, TAC-28). La base refuse avec son motif ce qui ne
// tient pas, et l'appli l'affiche tel quel (APP-5).

private func refus(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

/// Un jour tel que l'API l'attend, « 2026-10-23 » : sans heure ni fuseau, pour
/// que minuit à Paris ne devienne pas la veille en UTC.
private func jourAPI(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Ce qu'un écran des tâches dit en démonstration.
private struct HorsServeur: View {
    let texte: String

    var body: some View {
        Section {
            Label(texte, systemImage: "wifi.slash").foregroundStyle(Palette.texteSecondaire)
        }
    }
}

// MARK: - Un type en puce                                                  (TAC-25)

/// Un type de tâche qu'on touche pour le choisir : sa pastille à sa couleur.
struct PuceType: View {
    let type: TypeTache
    let choisie: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(Color(hexa: type.couleur) ?? Palette.texteSecondaire)
                    .frame(width: 10, height: 10)
                Text(type.libelle).texte(.corps).foregroundStyle(Palette.textePrincipal)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(choisie ? theme.principalVoile : Palette.verreTeinte, in: Capsule())
            .overlay(Capsule().strokeBorder(choisie ? theme.principal : Palette.verreBord,
                                            lineWidth: choisie ? 1 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choisie ? .isSelected : [])
    }
}

/// La pastille d'un type : son icône sur sa couleur, comme une ligne de réglage.
struct PastilleType: View {
    let type: TypeTache?

    var body: some View {
        Pastille(icone: type?.icone ?? "checklist",
                 couleur: type.flatMap { Color(hexa: $0.couleur) } ?? Categorie.menage.couleur)
    }
}

/// Les types du foyer en puces, et « + Nouveau type » qui en crée un d'un geste (TAC-26).
private struct ChoixDuType: View {
    @Binding var choisi: Int?
    var quandChoisi: (TypeTache) -> Void = { _ in }
    @Environment(Foyer.self) private var foyer
    @State private var nouveau = false

    var body: some View {
        Flux(espacement: 6) {
            ForEach(foyer.types) { type in
                PuceType(type: type, choisie: choisi == type.id) {
                    choisi = type.id
                    quandChoisi(type)
                }
            }
            if foyer.droits.modifier && foyer.connecte {
                PuceChoix(texte: "+ Nouveau type", choisie: false) { nouveau = true }
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $nouveau) {
            NavigationStack {
                FormulaireType(type: nil) { cree in
                    if let cree {
                        choisi = cree.id
                        quandChoisi(cree)
                    }
                }
            }
            .feuilleEnVerre()
        }
    }
}

// MARK: - Nouvelle tâche                                  (TAC-20 à TAC-24, FOY-6)

struct FormulaireTache: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer

    enum Maniere: String, CaseIterable, Identifiable {
        case uneFois = "Une fois"
        case reguliere = "Régulière"
        case apres = "Après une autre"
        var id: String { rawValue }
    }

    enum Moment: String, CaseIterable, Identifiable {
        case aujourdhui = "Aujourd'hui"
        case dates = "Du … au …"
        var id: String { rawValue }
    }

    enum Delai: String, CaseIterable, Identifiable {
        case jourMeme = "Le jour même"
        case lendemain = "Le lendemain"
        case heures = "En heures"
        var id: String { rawValue }
    }

    @State private var libelle = ""
    @State private var idType: Int?
    @State private var duree = 15
    @State private var maniere = Maniere.uneFois
    @State private var moment = Moment.aujourdhui
    @State private var du = Date.now
    @State private var au = Date.now
    @State private var oublier = false
    @State private var tousLes = 7
    @State private var apres: Int?
    @State private var delai = Delai.lendemain
    @State private var delaiMin = 8
    @State private var delaiMax = 20
    @State private var heure = ChoixHeure()
    @State private var pourQui: Int? = nil
    @State private var taches: [TacheRecurrente] = []
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
                TextField("Arroser le ficus", text: $libelle)
                Stepper("Durée : \(duree) min", value: $duree, in: 5...240, step: 5)
            }
            Section {
                ChoixDuType(choisi: $idType) { duree = $0.dureeMinutes ?? duree }
            } header: {
                Text("Type")
            }
            Section {
                Picker("Quand", selection: $maniere) {
                    ForEach(Maniere.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch maniere {
                case .uneFois: champsUneFois
                case .reguliere:
                    Stepper(tousLes == 1 ? "Tous les jours" : "Tous les \(tousLes) jours",
                            value: $tousLes, in: 1...365)
                case .apres: champsApres
                }
            } header: {
                Text("Quand")
            }
            if maniere == .uneFois {
                Section {
                    Picker("Si elle n'est pas faite", selection: $oublier) {
                        Text("La reporter").tag(false)
                        Text("L'oublier").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Si elle n'est pas faite")
                }
            }
            SectionHeure(heure: $heure, duree: duree)
            Section("Pour qui") {
                Picker("Pour qui", selection: $pourQui) {
                    Text("À tour de rôle").tag(Int?.none)
                    ForEach(foyer.membres) { Text($0.nom).tag(Int?.some($0.id)) }
                }
            }
            LigneErreur(texte: erreur)
            BoutonEnvoi(titre: "Ajouter la tâche", actif: peutEnvoyer, enCours: enCours) {
                Task { await envoyer() }
            }
        }
        .navigationTitle("Nouvelle tâche")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if idType == nil, let premier = foyer.types.first {
                idType = premier.id
                duree = premier.dureeMinutes ?? duree
            }
            if foyer.connecte, let toutes: [TacheRecurrente] = try? await foyer.demander("GET", "taches") {
                taches = toutes.filter { $0.categorie != "sport" }
            }
        }
    }

    @ViewBuilder private var champsUneFois: some View {
        Picker("Dates", selection: $moment) {
            ForEach(Moment.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        if moment == .dates {
            DatePicker("Pas avant le", selection: $du, in: Calendar.current.startOfDay(for: .now)...,
                       displayedComponents: .date)
                .onChange(of: du) { if au < du { au = du } }
            DatePicker("Au plus tard le", selection: $au, in: Calendar.current.startOfDay(for: du)...,
                       displayedComponents: .date)
        }
    }

    @ViewBuilder private var champsApres: some View {
        Picker("Après", selection: $apres) {
            Text("Choisir une tâche").tag(Int?.none)
            ForEach(taches) { Text($0.libelle).tag(Int?.some($0.idTache)) }
        }
        Picker("Délai", selection: $delai) {
            ForEach(Delai.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        if delai == .heures {
            Stepper("Au plus tôt \(delaiMin) h après", value: $delaiMin, in: 0...(delaiMax - 1))
            Stepper("Au plus tard \(delaiMax) h après", value: $delaiMax, in: (delaiMin + 1)...336)
        }
    }

    private var peutEnvoyer: Bool {
        !libelle.trimmingCharacters(in: .whitespaces).isEmpty && foyer.droits.ajouter
            && (maniere != .apres || apres != nil)
    }

    private struct Demande: Encodable {
        let libelle: String
        let idTypeTache: Int?
        let dureeMinutes: Int
        let pour: Int?
        var tousLesJours: Int? = nil
        var du: String? = nil
        var au: String? = nil
        var apres: Int? = nil
        var delaiMinHeures: Int? = nil
        var delaiMaxHeures: Int? = nil
        var heureMin: String? = nil
        var heureMax: String? = nil
        var siPasFaite: String = "reporter"
    }

    private func envoyer() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        let propre = libelle.trimmingCharacters(in: .whitespaces)
        var demande = Demande(libelle: propre, idTypeTache: idType, dureeMinutes: duree, pour: pourQui)
        switch maniere {
        case .uneFois:
            let aujourdhui = Date.now
            demande.du = jourAPI(moment == .aujourdhui ? aujourdhui : du)
            demande.au = jourAPI(moment == .aujourdhui ? aujourdhui : au)
            demande.siPasFaite = oublier ? "oublier" : "reporter"
        case .reguliere:
            demande.tousLesJours = tousLes
        case .apres:
            demande.apres = apres
            switch delai {
            case .jourMeme: (demande.delaiMinHeures, demande.delaiMaxHeures) = (0, 12)
            case .lendemain: (demande.delaiMinHeures, demande.delaiMaxHeures) = (12, 36)
            case .heures: (demande.delaiMinHeures, demande.delaiMaxHeures) = (delaiMin, delaiMax)
            }
        }
        if let plage = heure.plage(duree: duree) {
            demande.heureMin = plage.debut.api
            demande.heureMax = plage.fin.api
        }
        do {
            try await foyer.agir("POST", "taches/nouvelle", corps: ClientAPI.corps(demande))
            annoncer("« \(propre) » ajoutée")
            (fermerFeuille?.fermer ?? { fermer() })()
        } catch {
            erreur = refus(error)
        }
    }
}

// MARK: - L'heure d'une tâche                                              (TAC-23)

/// Sans heure, « à 18h30 », ou « entre 18h et 21h ».
struct ChoixHeure: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case sans = "Sans heure"
        case a = "À une heure"
        case entre = "Entre deux"
        var id: String { rawValue }
    }

    var mode = Mode.sans
    var a = HeureDuJour(minutes: 18 * 60 + 30)
    var debut = HeureDuJour(minutes: 18 * 60)
    var fin = HeureDuJour(minutes: 21 * 60)

    /// La plage envoyée à l'API : « à 18h30 » dure exactement la tâche.
    func plage(duree: Int) -> (debut: HeureDuJour, fin: HeureDuJour)? {
        switch mode {
        case .sans: nil
        case .a: (a, HeureDuJour(minutes: a.minutes + duree))
        case .entre: (debut, fin)
        }
    }

    /// Ce que dit une tâche déjà en base.
    init() {}

    init(tache: TacheRecurrente) {
        guard !tache.sansHeure, let debut = HeureDuJour(tache.heureMin), let fin = HeureDuJour(tache.heureMax) else { return }
        if tache.aUneHeure {
            mode = .a
            a = debut
        } else {
            mode = .entre
            self.debut = debut
            self.fin = fin
        }
    }
}

private struct SectionHeure: View {
    @Binding var heure: ChoixHeure
    let duree: Int

    var body: some View {
        Section {
            Picker("Heure", selection: $heure.mode) {
                ForEach(ChoixHeure.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch heure.mode {
            case .sans:
                EmptyView()
            case .a:
                DatePicker("À", selection: lien(\.a), displayedComponents: .hourAndMinute)
            case .entre:
                DatePicker("Entre", selection: lien(\.debut), displayedComponents: .hourAndMinute)
                DatePicker("Et", selection: lien(\.fin), displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Heure")
        }
    }

    private func lien(_ chemin: WritableKeyPath<ChoixHeure, HeureDuJour>) -> Binding<Date> {
        Binding(get: { heure[keyPath: chemin].date },
                set: { heure[keyPath: chemin] = HeureDuJour($0) })
    }
}

// MARK: - Toutes les tâches                                         (4.12, TAC-21)

struct EcranToutesLesTaches: View {
    @Environment(Foyer.self) private var foyer
    @State private var taches: [TacheRecurrente]?
    @State private var erreur: String?
    @State private var ajout = false

    var body: some View {
        FormulaireVerre {
            if !foyer.connecte {
                HorsServeur(texte: "Connecte-toi à ton serveur pour voir les tâches du foyer.")
            } else if let taches {
                if taches.isEmpty {
                    Section { Text("Aucune tâche dans le foyer.").foregroundStyle(Palette.texteSecondaire) }
                }
                ForEach(groupes(taches), id: \.titre) { groupe in
                    Section(groupe.titre) {
                        ForEach(groupe.taches) { tache in
                            NavigationLink {
                                EcranDetailTache(idTache: tache.idTache)
                            } label: {
                                HStack(spacing: 12) {
                                    PastilleType(type: tache.type)
                                    Text(tache.libelle).foregroundStyle(Palette.textePrincipal)
                                    Spacer(minLength: 8)
                                    Text([tache.rythme, tache.heure].compactMap { $0 }.filter { !$0.isEmpty }
                                            .joined(separator: " · "))
                                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
                if foyer.droits.ajouter {
                    Section {
                        Button { ajout = true } label: { Label("Ajouter une tâche", systemImage: "plus") }
                    }
                }
            } else if let erreur {
                LigneErreur(texte: erreur)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Toutes les tâches")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Maison, toutes les tâches")
        .task { await charger() }
        .refreshable { await charger() }
        .sheet(isPresented: $ajout, onDismiss: { Task { await charger() } }) {
            NavigationStack { FormulaireTache() }.feuilleEnVerre()
        }
    }

    private struct Groupe {
        let titre: String
        let taches: [TacheRecurrente]
    }

    /// Rangées par type, dans l'ordre des types du foyer ; le sport a son onglet.
    private func groupes(_ liste: [TacheRecurrente]) -> [Groupe] {
        let menage = liste.filter { $0.categorie != "sport" }
        var vus = Set<Int>()
        var resultat: [Groupe] = []
        for type in foyer.types {
            let siennes = menage.filter { $0.type?.id == type.id }
            if !siennes.isEmpty { resultat.append(Groupe(titre: type.libelle, taches: siennes)) }
            vus.insert(type.id)
        }
        let autres = menage.filter { tache in tache.type.map { type in !vus.contains(type.id) } ?? true }
        if !autres.isEmpty { resultat.append(Groupe(titre: "Autres", taches: autres)) }
        return resultat
    }

    private func charger() async {
        do {
            let lues: [TacheRecurrente] = try await foyer.demander("GET", "taches")
            taches = lues
            erreur = nil
            await foyer.rechargerTypes()
        } catch {
            erreur = refus(error)
        }
    }
}

// MARK: - Détail d'une tâche                                 (4.2, TAC-21, TAC-27)

struct EcranDetailTache: View {
    let idTache: Int
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer

    @State private var tache: TacheRecurrente?
    @State private var liens: [LienTache] = []
    @State private var libelle = ""
    @State private var idType: Int?
    @State private var duree = 15
    @State private var tousLes = 7
    /// Le rythme lu : on ne renvoie la périodicité que s'il a changé, pour ne
    /// pas élargir une tâche sans jeu comme les poubelles (TAC-11).
    @State private var tousLesLu = 7
    @State private var heure = ChoixHeure()
    @State private var pourQui: Int?
    @State private var ajoutLien = false
    @State private var confirmerArret = false
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            if let tache {
                let modifiable = foyer.droits.modifier
                Section {
                    TextField("Nom", text: $libelle).disabled(!modifiable)
                    Stepper("Durée : \(duree) min", value: $duree, in: 5...240, step: 5).disabled(!modifiable)
                    if tache.recurrente != false {
                        Stepper(tousLes == 1 ? "Tous les jours" : "Tous les \(tousLes) jours",
                                value: $tousLes, in: 1...365).disabled(!modifiable)
                    } else {
                        LabeledContent("Quand", value: tache.rythme)
                    }
                } header: {
                    Text(modifiable ? "La tâche (modifiable)" : "La tâche")
                } footer: {
                    if !modifiable { Text("Seul l'administrateur du foyer modifie les tâches.") }
                }
                Section("Type") {
                    ChoixDuType(choisi: $idType).disabled(!modifiable)
                }
                SectionHeure(heure: $heure, duree: duree).disabled(!modifiable)
                Section("Pour qui") {
                    Picker("Pour qui", selection: $pourQui) {
                        Text("À tour de rôle").tag(Int?.none)
                        ForEach(foyer.membres) { Text($0.nom).tag(Int?.some($0.id)) }
                    }
                    .disabled(!modifiable)
                }
                Section {
                    if liens.isEmpty {
                        Text("Aucun lien : elle se place seule.").foregroundStyle(Palette.texteSecondaire)
                    }
                    ForEach(liens) { lien in
                        LigneLien(lien: lien)
                            .swipeActions {
                                if modifiable {
                                    Button("Retirer", role: .destructive) { Task { await retirer(lien) } }
                                }
                            }
                    }
                    if modifiable {
                        Button { ajoutLien = true } label: { Label("Ajouter un lien", systemImage: "plus") }
                    }
                } header: {
                    Text("Liens")
                }
                LigneErreur(texte: erreur)
                if modifiable {
                    BoutonEnvoi(titre: "Enregistrer", actif: !libelle.trimmingCharacters(in: .whitespaces).isEmpty,
                                enCours: enCours) { Task { await enregistrer() } }
                    Section {
                        Button("Arrêter la tâche", role: .destructive) { confirmerArret = true }
                    }
                }
            } else if let erreur {
                LigneErreur(texte: erreur)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle(tache?.libelle ?? "Tâche")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Maison, détail d'une tâche")
        .task { await charger() }
        .sheet(isPresented: $ajoutLien) {
            NavigationStack {
                FormulaireLien(depuis: idTache, libelle: tache?.libelle ?? "") { await chargerLiens() }
            }
            .feuilleEnVerre()
        }
        .confirmationDialog("Arrêter « \(tache?.libelle ?? "") » ?", isPresented: $confirmerArret,
                            titleVisibility: .visible) {
            Button("Arrêter", role: .destructive) { Task { await arreter() } }
        }
    }

    private func charger() async {
        do {
            let toutes: [TacheRecurrente] = try await foyer.demander("GET", "taches")
            guard let lue = toutes.first(where: { $0.idTache == idTache }) else {
                erreur = "Cette tâche n'existe plus"
                return
            }
            tache = lue
            libelle = lue.libelle
            idType = lue.type?.id
            duree = lue.dureeMinutes ?? duree
            tousLes = lue.periodiciteMinJours ?? tousLes
            tousLesLu = tousLes
            heure = ChoixHeure(tache: lue)
            pourQui = lue.idUtilisateurDefaut
            await chargerLiens()
        } catch {
            erreur = refus(error)
        }
    }

    private func chargerLiens() async {
        if let lus: [LienTache] = try? await foyer.demander("GET", "taches/\(idTache)/liens") {
            liens = lus
        }
    }

    private struct Modification: Encodable {
        let libelle: String
        let dureeMinutes: Int
        var periodiciteMinJours: Int? = nil
        var periodiciteMaxJours: Int? = nil
        let idUtilisateurDefaut: Int?
        let idTypeTache: Int?
        var sansHeure = false
        var heureMin: String? = nil
        var heureMax: String? = nil

        // « pour qui » vide veut dire « à tour de rôle » : il part, même nul.
        enum CodingKeys: String, CodingKey {
            case libelle, dureeMinutes, periodiciteMinJours, periodiciteMaxJours
            case idUtilisateurDefaut, idTypeTache, sansHeure, heureMin, heureMax
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(libelle, forKey: .libelle)
            try c.encode(dureeMinutes, forKey: .dureeMinutes)
            try c.encodeIfPresent(periodiciteMinJours, forKey: .periodiciteMinJours)
            try c.encodeIfPresent(periodiciteMaxJours, forKey: .periodiciteMaxJours)
            try c.encode(idUtilisateurDefaut, forKey: .idUtilisateurDefaut)
            try c.encodeIfPresent(idTypeTache, forKey: .idTypeTache)
            try c.encode(sansHeure, forKey: .sansHeure)
            try c.encodeIfPresent(heureMin, forKey: .heureMin)
            try c.encodeIfPresent(heureMax, forKey: .heureMax)
        }
    }

    private func enregistrer() async {
        guard let tache else { return }
        enCours = true
        erreur = nil
        defer { enCours = false }
        var demande = Modification(libelle: libelle.trimmingCharacters(in: .whitespaces),
                                   dureeMinutes: duree, idUtilisateurDefaut: pourQui,
                                   idTypeTache: idType == tache.type?.id ? nil : idType)
        if tache.recurrente != false && tousLes != tousLesLu {
            demande.periodiciteMinJours = tousLes
            demande.periodiciteMaxJours = tousLes + max(1, tousLes / 7)
        }
        if let plage = heure.plage(duree: duree) {
            demande.heureMin = plage.debut.api
            demande.heureMax = plage.fin.api
        } else {
            demande.sansHeure = !tache.sansHeure
        }
        do {
            try await foyer.agir("PATCH", "taches/\(idTache)", corps: ClientAPI.corps(demande))
            annoncer("« \(demande.libelle) » enregistrée")
            await charger()
        } catch {
            erreur = refus(error)
        }
    }

    private func retirer(_ lien: LienTache) async {
        do {
            try await foyer.agir("DELETE", "taches/liens/\(lien.sorte)/\(lien.idLien)")
            await chargerLiens()
        } catch {
            erreur = refus(error)
        }
    }

    private func arreter() async {
        do {
            try await foyer.agir("DELETE", "taches/\(idTache)")
            annoncer("« \(tache?.libelle ?? "") » arrêtée")
            fermer()
        } catch {
            erreur = refus(error)
        }
    }
}

/// Un lien lu depuis la tâche ouverte : sa sorte, et la phrase de la base.
private struct LigneLien: View {
    let lien: LienTache

    var body: some View {
        HStack(spacing: 12) {
            Pastille(icone: lien.icone, couleur: Palette.verreTeinteForte)
            VStack(alignment: .leading, spacing: 1) {
                Text(lien.etiquette).texte(.etiquette).foregroundStyle(Palette.texteTertiaire)
                Text(lien.phrase).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Ajouter un lien                                          (4.11, TAC-27)

struct FormulaireLien: View {
    let depuis: Int
    let libelle: String
    var apres: () async -> Void = {}
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer

    enum Sorte: String, CaseIterable, Identifiable {
        case ensuite = "Ensuite"
        case memeJour = "Le même jour"
        case vautAussi = "Vaut aussi"
        var id: String { rawValue }
        var api: String {
            switch self {
            case .ensuite: "ensuite"
            case .memeJour: "meme_jour"
            case .vautAussi: "vaut_aussi"
            }
        }
    }

    @State private var sorte = Sorte.ensuite
    @State private var autre: Int?
    @State private var delai = FormulaireTache.Delai.lendemain
    @State private var delaiMin = 8
    @State private var delaiMax = 20
    @State private var avant = true
    @State private var taches: [TacheRecurrente] = []
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            Section {
                Picker("Sorte", selection: $sorte) {
                    ForEach(Sorte.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Quelle tâche", selection: $autre) {
                    Text("Choisir").tag(Int?.none)
                    ForEach(taches.filter { $0.idTache != depuis }) {
                        Text($0.libelle).tag(Int?.some($0.idTache))
                    }
                }
            } header: {
                Text("Depuis « \(libelle) »")
            }
            switch sorte {
            case .ensuite:
                Section("Quand elle naît") {
                    Picker("Délai", selection: $delai) {
                        ForEach(FormulaireTache.Delai.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if delai == .heures {
                        Stepper("Au plus tôt \(delaiMin) h après", value: $delaiMin, in: 0...(delaiMax - 1))
                        Stepper("Au plus tard \(delaiMax) h après", value: $delaiMax, in: (delaiMin + 1)...336)
                    }
                }
            case .memeJour:
                Section("Place") {
                    Picker("Place", selection: $avant) {
                        Text("Avant elle").tag(true)
                        Text("Après elle").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            case .vautAussi:
                EmptyView()
            }
            Section("Ce que ça donne") {
                Text(phrase).foregroundStyle(Palette.textePrincipal)
            }
            LigneErreur(texte: erreur)
            BoutonEnvoi(titre: "Ajouter le lien", actif: autre != nil, enCours: enCours) {
                Task { await envoyer() }
            }
        }
        .navigationTitle("Ajouter un lien")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Fermer") { fermer() } }
        }
        .task {
            if let toutes: [TacheRecurrente] = try? await foyer.demander("GET", "taches") {
                taches = toutes.filter { $0.categorie != "sport" }
            }
        }
    }

    private var bornes: (Int, Int) {
        switch delai {
        case .jourMeme: (0, 12)
        case .lendemain: (12, 36)
        case .heures: (delaiMin, delaiMax)
        }
    }

    private var phrase: String {
        let nom = taches.first { $0.idTache == autre }?.libelle ?? "l'autre tâche"
        switch sorte {
        case .ensuite:
            let (min, max) = bornes
            return "Quand « \(libelle) » est faite, « \(nom) » naît entre \(min) et \(max) heures après."
        case .memeJour:
            return "Quand « \(libelle) » est prévue, « \(nom) » vient le même jour, \(avant ? "avant" : "après") elle, pour la même personne."
        case .vautAussi:
            return "Faire « \(libelle) » solde aussi « \(nom) », le même jour."
        }
    }

    private struct Demande: Encodable {
        let sorte: String
        let idAutre: Int
        let delaiMinHeures: Int
        let delaiMaxHeures: Int
        let place: String
    }

    private func envoyer() async {
        guard let autre else { return }
        enCours = true
        erreur = nil
        defer { enCours = false }
        let (min, max) = bornes
        do {
            try await foyer.agir("POST", "taches/\(depuis)/liens", corps: ClientAPI.corps(Demande(
                sorte: sorte.api, idAutre: autre, delaiMinHeures: min, delaiMaxHeures: max,
                place: avant ? "avant" : "apres")))
            await apres()
            fermer()
        } catch {
            erreur = refus(error)
        }
    }
}

// MARK: - Types de tâches                                    (4.9, TAC-25, TAC-26)

struct EcranTypesTaches: View {
    @Environment(Foyer.self) private var foyer
    @State private var nouveau = false

    var body: some View {
        FormulaireVerre {
            Section {
                ForEach(foyer.types) { type in
                    NavigationLink {
                        FormulaireType(type: type)
                    } label: {
                        HStack(spacing: 12) {
                            PastilleType(type: type)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(type.libelle).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                Text(detail(type)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            }
                        }
                    }
                    .disabled(!foyer.droits.modifier || !foyer.connecte)
                }
            }
            if foyer.droits.modifier && foyer.connecte {
                Section {
                    Button { nouveau = true } label: { Label("Nouveau type", systemImage: "plus") }
                }
            }
        }
        .navigationTitle("Types de tâches")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, types de tâches")
        .task { await foyer.rechargerTypes() }
        .refreshable { await foyer.rechargerTypes() }
        .sheet(isPresented: $nouveau) {
            NavigationStack { FormulaireType(type: nil) }.feuilleEnVerre()
        }
    }

    private func detail(_ type: TypeTache) -> String {
        let n = type.taches ?? 0
        let combien = n == 0 ? "Aucune tâche" : "\(n) tâche\(n > 1 ? "s" : "")"
        return "\(combien) · \(type.dureeMinutes ?? 15) min, priorité \(type.priorite ?? 4)"
    }
}

// MARK: - Un type de tâche                                       (4.10, TAC-25, TAC-26)

struct FormulaireType: View {
    /// Vide : un type à créer.
    let type: TypeTache?
    var quandEnregistre: (TypeTache?) -> Void = { _ in }
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer

    /// Des symboles qui disent la maison ; d'autres s'écrivent à la main.
    static let icones = ["house", "tshirt", "fork.knife", "pawprint", "doc.text", "leaf",
                         "book", "cart", "trash", "drop", "flame", "car",
                         "checklist", "star", "heart", "bolt", "moon", "wrench.and.screwdriver"]

    @State private var libelle = ""
    @State private var couleur = Color(hex: 0x7ED957)
    @State private var icone = "checklist"
    @State private var duree = 15
    @State private var priorite = 4
    @State private var confirmerSuppression = false
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            Section("Nom") {
                TextField("Plantes", text: $libelle)
            }
            Section("Couleur") {
                ColorPicker("Couleur", selection: $couleur, supportsOpacity: false)
            }
            Section("Icône") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                    ForEach(Self.icones, id: \.self) { nom in
                        Button { icone = nom } label: {
                            Image(systemName: nom)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(icone == nom ? Palette.texteSurAccent : Palette.textePrincipal)
                                .frame(width: 44, height: 44)
                                .background(icone == nom ? couleur : Palette.verreTeinte,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(icone == nom ? Palette.textePrincipal : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(nom)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Stepper("Durée : \(duree) min", value: $duree, in: 5...240, step: 5)
                Picker("Priorité", selection: $priorite) {
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Pour ses nouvelles tâches")
            } footer: {
                Text("Priorité 1 : n'attend pas ; 5 : peut attendre.")
            }
            Section("Aperçu") {
                HStack(spacing: 12) {
                    Pastille(icone: icone, couleur: couleur)
                    Text(libelle.isEmpty ? "Nouveau type" : libelle).foregroundStyle(Palette.textePrincipal)
                }
            }
            LigneErreur(texte: erreur)
            BoutonEnvoi(titre: type == nil ? "Créer le type" : "Enregistrer",
                        actif: !libelle.trimmingCharacters(in: .whitespaces).isEmpty, enCours: enCours) {
                Task { await envoyer() }
            }
            if let type {
                Section {
                    Button("Supprimer le type", role: .destructive) { confirmerSuppression = true }
                        .disabled((type.taches ?? 0) > 0)
                } footer: {
                    if (type.taches ?? 0) > 0 {
                        Text("Il porte encore \(type.taches ?? 0) tâche(s) : change-les de type pour pouvoir le supprimer.")
                    }
                }
            }
        }
        .navigationTitle(type?.libelle ?? "Nouveau type")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let type else { return }
            libelle = type.libelle
            couleur = Color(hexa: type.couleur) ?? couleur
            icone = type.icone
            duree = type.dureeMinutes ?? duree
            priorite = type.priorite ?? priorite
        }
        .confirmationDialog("Supprimer « \(type?.libelle ?? "") » ?", isPresented: $confirmerSuppression,
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { Task { await supprimer() } }
        }
    }

    private struct Demande: Encodable {
        let libelle: String
        let couleur: String
        let icone: String
        let dureeMinutes: Int
        let priorite: Int
    }

    private func envoyer() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        let demande = Demande(libelle: libelle.trimmingCharacters(in: .whitespaces), couleur: couleur.hexa,
                              icone: icone, dureeMinutes: duree, priorite: priorite)
        do {
            let enregistre: TypeTache = try await foyer.demander(type == nil ? "POST" : "PATCH",
                                                                 type.map { "types-taches/\($0.id)" } ?? "types-taches",
                                                                 corps: ClientAPI.corps(demande))
            await foyer.charger()
            annoncer("« \(enregistre.libelle) » enregistré")
            quandEnregistre(enregistre)
            fermer()
        } catch {
            erreur = refus(error)
        }
    }

    private func supprimer() async {
        guard let type else { return }
        do {
            try await foyer.agir("DELETE", "types-taches/\(type.id)")
            quandEnregistre(nil)
            fermer()
        } catch {
            erreur = refus(error)
        }
    }
}
