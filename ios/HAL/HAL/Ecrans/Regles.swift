import SwiftUI

// Les règles spéciales d'une tâche, à la main (CND-11, CND-16) : « le mardi ou
// le jeudi », « un jour sans aucune occupation pour Thomas », « quand l'autre
// n'est pas là ». Une règle est faite de briques ; le moteur ne place la tâche
// qu'un jour où toutes tiennent. La traduction vient de la base, jamais de
// l'appli : ce qu'on lit est ce que la base appliquera (CND-2).

private func refus(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

/// « 2026-10-23 » ↔ une date du calendrier, sans fuseau.
private enum JourAPI {
    static func texte(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ texte: String) -> Date? {
        let morceaux = texte.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard morceaux.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: morceaux[0], month: morceaux[1], day: morceaux[2]))
    }

    /// « jeu. 23/10 ».
    static func court(_ texte: String) -> String {
        guard let date = date(texte) else { return texte }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits))
    }
}

// MARK: - Les briques connues                                    (CND-3 à CND-6)

enum NatureBrique: String, CaseIterable, Identifiable {
    case joursSemaine = "jours_semaine"
    case dates
    case jourDuMois = "jour_du_mois"
    case joursInterdits = "jours_interdits"
    case journeeVide = "journee_vide"
    case sansCoursNiTravail = "sans_cours_ni_travail"
    case demiJournee = "demi_journee"
    case heuresMax = "heures_max"
    case veilleSansCours = "veille_sans_cours"
    case lendemainSansCours = "lendemain_sans_cours"
    case tempsLibreMin = "temps_libre_min"
    case autreAbsent = "autre_absent"
    case tousPresents = "tous_presents"
    case auRetour = "au_retour"
    case avantDepart = "avant_depart"

    var id: String { rawValue }

    enum Famille: String, CaseIterable {
        case jours = "Jours et dates"
        case agenda = "Selon l'agenda"
        case presence = "Selon la présence"
    }

    var famille: Famille {
        switch self {
        case .joursSemaine, .dates, .jourDuMois, .joursInterdits: .jours
        case .autreAbsent, .tousPresents, .auRetour, .avantDepart: .presence
        default: .agenda
        }
    }

    var titre: String {
        switch self {
        case .joursSemaine: "Certains jours de la semaine"
        case .dates: "Des dates précises"
        case .jourDuMois: "Un jour du mois"
        case .joursInterdits: "Jamais certains jours"
        case .journeeVide: "Une journée sans aucune occupation"
        case .sansCoursNiTravail: "Une journée sans cours ni travail"
        case .demiJournee: "Une demi-journée libre"
        case .heuresMax: "Peu de cours ce jour-là"
        case .veilleSansCours: "La veille d'un jour sans cours"
        case .lendemainSansCours: "Le lendemain d'un jour sans cours"
        case .tempsLibreMin: "Assez de temps libre"
        case .autreAbsent: "Quand l'autre n'est pas là"
        case .tousPresents: "Quand vous êtes là tous les deux"
        case .auRetour: "Au retour d'un voyage"
        case .avantDepart: "Avant un départ"
        }
    }

    /// L'agenda et la présence disent pour qui ; les jours et les dates non.
    var ditPourQui: Bool { famille != .jours && self != .tousPresents }

    func nouvelle() -> BriqueRegle {
        var brique = BriqueRegle(nature: rawValue)
        if famille != .jours { brique.pourQui = self == .tousPresents ? "les_deux" : "assigne" }
        switch self {
        case .joursSemaine: brique.parametres.jours = [6]
        case .joursInterdits: brique.parametres.jours = [7]
        case .dates:
            let dans7 = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
            brique.parametres.dates = [JourAPI.texte(dans7)]
        case .jourDuMois: brique.parametres.rang = 1
        case .demiJournee: brique.parametres.partie = "matin"
        case .heuresMax: brique.parametres.heures = 4
        case .tempsLibreMin: brique.parametres.minutes = 120
        case .avantDepart: brique.parametres.joursAvant = 2
        default: break
        }
        return brique
    }
}

// MARK: - La section du détail d'une tâche                       (4.2, CND-16)

struct SectionRegles: View {
    let idTache: Int
    let libelle: String
    let modifiable: Bool
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer

    @State private var lues = ReglesDeTache()
    @State private var ajout = false
    @State private var erreur: String?

    var body: some View {
        Section {
            if lues.regles.isEmpty {
                Text("Aucune règle : elle se place où il y a de la place.")
                    .foregroundStyle(Palette.texteSecondaire)
            }
            ForEach(lues.regles) { regle in
                LigneRegle(regle: regle)
                    .swipeActions {
                        if modifiable && (regle.etat == "active" || regle.etat == "suspendue") {
                            Button("Retirer", role: .destructive) { Task { await retirer(regle) } }
                            Button(regle.active ? "Suspendre" : "Reprendre") {
                                Task { await basculer(regle) }
                            }
                            .tint(Palette.verreTeinteForte)
                        }
                    }
            }
            if !lues.prochainsJours.isEmpty {
                LabeledContent("Prochains jours possibles",
                               value: lues.prochainsJours.map(JourAPI.court).joined(separator: ", "))
            }
            LigneErreur(texte: erreur)
            if modifiable {
                Button { ajout = true } label: { Label("Ajouter une règle", systemImage: "plus") }
            }
        } header: {
            Text("Règles spéciales")
        }
        .task { await charger() }
        .sheet(isPresented: $ajout) {
            NavigationStack {
                FormulaireRegle(idTache: idTache, libelle: libelle) { await charger() }
            }
            .feuilleEnVerre()
        }
    }

    private func charger() async {
        do {
            lues = try await foyer.demander("GET", "taches/\(idTache)/regles")
        } catch {
            erreur = refus(error)
        }
    }

    private struct Etat: Encodable { let etat: String }

    private func basculer(_ regle: RegleTache) async {
        do {
            lues = try await foyer.demander("PATCH", "regles/\(regle.id)", corps: ClientAPI.corps(
                Etat(etat: regle.active ? "suspendue" : "active")))
            annoncer(regle.active ? "Règle suspendue" : "Règle reprise")
        } catch {
            erreur = refus(error)
        }
    }

    private func retirer(_ regle: RegleTache) async {
        do {
            lues = try await foyer.demander("DELETE", "regles/\(regle.id)")
            annoncer("Règle retirée")
        } catch {
            erreur = refus(error)
        }
    }
}

/// Une règle lue : sa traduction, sa période, et ce qui la rend inopérante.
private struct LigneRegle: View {
    let regle: RegleTache

    var body: some View {
        HStack(spacing: 12) {
            Pastille(icone: icone, couleur: Palette.verreTeinteForte)
            VStack(alignment: .leading, spacing: 2) {
                Text(regle.traduction).texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).texte(.etiquette).foregroundStyle(Palette.texteTertiaire)
                }
            }
        }
        .opacity(regle.active ? 1 : 0.55)
    }

    private var icone: String {
        if regle.impossibleDepuis != nil && regle.active { return "exclamationmark.triangle" }
        return regle.active ? "calendar.badge.checkmark" : "pause.circle"
    }

    private var detail: String? {
        switch regle.etat {
        case "suspendue": return "SUSPENDUE"
        case "retiree": return "RETIRÉE"
        case "expiree": return "TERMINÉE"
        default:
            if regle.impossibleDepuis != nil { return "AUCUN JOUR NE LA TIENT EN CE MOMENT" }
            return regle.poseeParNom.map { "POSÉE PAR \($0.uppercased())" }
        }
    }
}

// MARK: - Poser une règle, brique par brique                         (CND-11)

struct FormulaireRegle: View {
    let idTache: Int
    let libelle: String
    var apres: () async -> Void = {}
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer

    @State private var briques: [BriqueRegle] = []
    @State private var periode = false
    @State private var du = Date.now
    @State private var au = Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now
    @State private var chaqueAnnee = false
    @State private var changerFrequence = false
    @State private var tousLes = 2
    @State private var essai: EssaiRegle?
    @State private var enCours = false
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            Section {
                Menu {
                    ForEach(NatureBrique.Famille.allCases, id: \.self) { famille in
                        Section(famille.rawValue) {
                            ForEach(NatureBrique.allCases.filter { $0.famille == famille }) { nature in
                                Button(nature.titre) { briques.append(nature.nouvelle()) }
                                    .disabled(briques.contains { $0.nature == nature.rawValue })
                            }
                        }
                    }
                } label: {
                    Label("Ajouter une brique", systemImage: "plus")
                }
            } header: {
                Text("Pour « \(libelle) »")
            } footer: {
                Text("Toutes les briques doivent tenir le même jour.")
            }

            ForEach($briques) { $brique in
                if let nature = NatureBrique(rawValue: brique.nature) {
                    Section {
                        EditeurBrique(nature: nature, brique: $brique)
                        Button("Retirer la brique", role: .destructive) {
                            briques.removeAll { $0.nature == brique.nature }
                        }
                    } header: {
                        Text(nature.titre)
                    }
                }
            }

            Section {
                Toggle("Seulement pendant une période", isOn: $periode.animation())
                if periode {
                    DatePicker("Du", selection: $du, displayedComponents: .date)
                        .onChange(of: du) { if au < du { au = du } }
                    DatePicker("Au", selection: $au, in: du..., displayedComponents: .date)
                    Toggle("Chaque année", isOn: $chaqueAnnee)
                    Toggle("Changer la fréquence pendant la période", isOn: $changerFrequence.animation())
                    if changerFrequence {
                        Stepper(tousLes == 1 ? "Tous les jours" : "Tous les \(tousLes) jours",
                                value: $tousLes, in: 1...60)
                    }
                }
            } header: {
                Text("Période")
            }

            Section("Ce que ça donne") {
                if let essai {
                    Text(essai.traduction ?? "").foregroundStyle(Palette.textePrincipal)
                    if essai.jours.isEmpty {
                        Label("Aucun jour possible dans les huit semaines", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Palette.texteSecondaire)
                    } else {
                        LabeledContent("Jours possibles",
                                       value: "\(essai.jours.count) en huit semaines")
                        Text(essai.jours.prefix(6).map(JourAPI.court).joined(separator: ", "))
                            .texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                    }
                } else {
                    Text("Ajoutez une brique.").foregroundStyle(Palette.texteSecondaire)
                }
            }
            LigneErreur(texte: erreur)
            BoutonEnvoi(titre: "Poser la règle", actif: !briques.isEmpty || (periode && changerFrequence),
                        enCours: enCours) { Task { await envoyer() } }
        }
        .navigationTitle("Règle spéciale")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Fermer") { fermer() } }
        }
        .task(id: definition) { await essayer() }
    }

    private struct Definition: Encodable, Hashable {
        var briques: [BriqueRegle]
        var du: String? = nil
        var au: String? = nil
        var chaqueAnnee = false
        var frequence: FrequenceRegle? = nil
    }

    private var definition: Definition {
        var d = Definition(briques: briques)
        if periode {
            d.du = JourAPI.texte(du)
            d.au = JourAPI.texte(au)
            d.chaqueAnnee = chaqueAnnee
            if changerFrequence { d.frequence = FrequenceRegle(min: tousLes, max: tousLes) }
        }
        return d
    }

    private func essayer() async {
        guard !briques.isEmpty else {
            essai = nil
            return
        }
        // Le temps de finir de toucher les boutons.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        do {
            essai = try await foyer.demander("POST", "taches/\(idTache)/regles/essayer",
                                             corps: ClientAPI.corps(definition))
            erreur = nil
        } catch {
            essai = nil
            erreur = refus(error)
        }
    }

    private func envoyer() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        do {
            try await foyer.agir("POST", "taches/\(idTache)/regles", corps: ClientAPI.corps(definition))
            annoncer("Règle posée")
            await apres()
            fermer()
        } catch {
            erreur = refus(error)
        }
    }
}

// MARK: - Les réglages d'une brique

private struct EditeurBrique: View {
    let nature: NatureBrique
    @Binding var brique: BriqueRegle
    @Environment(Foyer.self) private var foyer

    var body: some View {
        switch nature {
        case .joursSemaine, .joursInterdits:
            ChoixJoursSemaine(jours: Binding(get: { brique.parametres.jours ?? [] },
                                             set: { brique.parametres.jours = $0 }))
        case .dates:
            ChoixDates(dates: Binding(get: { brique.parametres.dates ?? [] },
                                      set: { brique.parametres.dates = $0 }))
        case .jourDuMois:
            ChoixJourDuMois(parametres: $brique.parametres)
        case .demiJournee:
            Picker("Laquelle", selection: Binding(get: { brique.parametres.partie ?? "matin" },
                                                  set: { brique.parametres.partie = $0 })) {
                Text("Le matin").tag("matin")
                Text("L'après-midi").tag("apres_midi")
            }
            .pickerStyle(.segmented)
        case .heuresMax:
            let heures = Int(brique.parametres.heures ?? 4)
            Stepper(heures == 0 ? "Aucun cours ni travail" : "Au plus \(heures) h de cours ou de travail",
                    value: Binding(get: { heures }, set: { brique.parametres.heures = Double($0) }),
                    in: 0...12)
        case .tempsLibreMin:
            let minutes = brique.parametres.minutes ?? 120
            Stepper("Au moins \(minutes / 60) h\(minutes % 60 == 0 ? "" : " 30") de libre",
                    value: Binding(get: { minutes }, set: { brique.parametres.minutes = $0 }),
                    in: 30...720, step: 30)
        case .avantDepart:
            let jours = brique.parametres.joursAvant ?? 2
            Stepper(jours == 0 ? "Le jour du départ" : "Dans les \(jours) jours avant",
                    value: Binding(get: { jours }, set: { brique.parametres.joursAvant = $0 }),
                    in: 0...14)
        default:
            EmptyView()
        }
        if nature.ditPourQui {
            Picker("Pour qui", selection: pourQui) {
                Text("Celui qui la fait").tag("assigne")
                ForEach(foyer.membres) { Text($0.nom).tag("m\($0.id)") }
                if nature != .autreAbsent { Text("Vous deux").tag("les_deux") }
            }
        }
    }

    /// « assigne », « les_deux », ou « m12 » pour un membre nommé.
    private var pourQui: Binding<String> {
        Binding(get: {
            if brique.pourQui == "nomme", let id = brique.idUtilisateur { return "m\(id)" }
            return brique.pourQui ?? "assigne"
        }, set: { choix in
            if choix.hasPrefix("m"), let id = Int(choix.dropFirst()) {
                brique.pourQui = "nomme"
                brique.idUtilisateur = id
            } else {
                brique.pourQui = choix
                brique.idUtilisateur = nil
            }
        })
    }
}

/// Les sept jours, à cocher. 1 pour lundi, comme la base.
private struct ChoixJoursSemaine: View {
    @Binding var jours: [Int]
    private let initiales = ["L", "M", "M", "J", "V", "S", "D"]
    private let noms = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { jour in
                let choisi = jours.contains(jour)
                Button {
                    if choisi { jours.removeAll { $0 == jour } } else { jours = (jours + [jour]).sorted() }
                } label: {
                    Text(initiales[jour - 1])
                        .texte(.corpsFort)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(choisi ? Palette.verreTeinteForte : .clear, in: .circle)
                        .overlay(Circle().stroke(Palette.texteTertiaire.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(noms[jour - 1])
                .accessibilityAddTraits(choisi ? .isSelected : [])
            }
        }
    }
}

private struct ChoixDates: View {
    @Binding var dates: [String]
    @State private var nouvelle = Date.now

    var body: some View {
        ForEach(dates, id: \.self) { jour in
            HStack {
                Text(JourAPI.date(jour)?.formatted(date: .complete, time: .omitted) ?? jour)
                Spacer()
                Button(role: .destructive) { dates.removeAll { $0 == jour } } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retirer cette date")
            }
        }
        DatePicker("Date", selection: $nouvelle, in: Calendar.current.startOfDay(for: .now)...,
                   displayedComponents: .date)
        Button {
            let jour = JourAPI.texte(nouvelle)
            if !dates.contains(jour) { dates = (dates + [jour]).sorted() }
        } label: {
            Label("Ajouter cette date", systemImage: "plus")
        }
    }
}

/// « Le 1er », « le dernier jour », « le deuxième samedi », « le dernier dimanche ».
private struct ChoixJourDuMois: View {
    @Binding var parametres: ParametresBrique
    private let rangs = [(1, "Premier"), (2, "Deuxième"), (3, "Troisième"), (4, "Quatrième"), (-1, "Dernier")]
    private let noms = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]

    var body: some View {
        Picker("Sorte", selection: parJourDeSemaine) {
            Text("Un numéro").tag(false)
            Text("Un jour de la semaine").tag(true)
        }
        .pickerStyle(.segmented)
        if parametres.jourSemaine == nil {
            Toggle("Le dernier jour du mois", isOn: Binding(
                get: { (parametres.rang ?? 1) < 0 },
                set: { parametres.rang = $0 ? -1 : 1 }))
            if (parametres.rang ?? 1) > 0 {
                Stepper("Le \(parametres.rang == 1 ? "1er" : "\(parametres.rang ?? 1)")",
                        value: Binding(get: { parametres.rang ?? 1 }, set: { parametres.rang = $0 }),
                        in: 1...31)
            }
        } else {
            Picker("Lequel", selection: Binding(get: { parametres.rang ?? 1 }, set: { parametres.rang = $0 })) {
                ForEach(rangs, id: \.0) { Text($0.1).tag($0.0) }
            }
            Picker("Jour", selection: Binding(get: { parametres.jourSemaine ?? 6 },
                                              set: { parametres.jourSemaine = $0 })) {
                ForEach(1...7, id: \.self) { Text(noms[$0 - 1]).tag($0) }
            }
        }
    }

    private var parJourDeSemaine: Binding<Bool> {
        Binding(get: { parametres.jourSemaine != nil }, set: { oui in
            parametres.jourSemaine = oui ? 6 : nil
            parametres.rang = 1
        })
    }
}
