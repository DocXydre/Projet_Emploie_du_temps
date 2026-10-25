import SwiftUI

// Réglages, groupe « HAL et sport » (5.5 à 5.9) : le profil, les limitations,
// les lieux, la mémoire, la pause, et le démarrage à reprendre ou à refaire.

private let enFrancais = Locale(identifier: "fr_FR")

private func raison(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

/// Une ligne d'erreur dans un formulaire.
private struct Refus: View {
    let texte: String?

    var body: some View {
        if let texte {
            Section {
                Label(texte, systemImage: "exclamationmark.circle").foregroundStyle(Categorie.alerte.couleur)
            }
        }
    }
}

// MARK: - 5.5 Profil sportif

/// PRO-2 : des questions fermées, qu'on modifie quand on veut. HAL ne recueille
/// pas le profil en discutant.
struct EcranProfilSportif: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @Environment(\.dismiss) private var fermer
    @State private var charge = false
    @State private var naissance = Date.now
    @State private var sexe = "homme"
    @State private var taille = 175
    @State private var niveauMusculation = "debutant"
    @State private var niveauCourse = "debutant"
    @State private var moment = "indifferent"
    @State private var jours: Set<Int> = []
    @State private var maximum: Int?
    @State private var complements = false
    @State private var regime = ""
    @State private var sansProfil = false
    @State private var envoi = false
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            if !charge {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if sansProfil {
                Section {
                    Text("Le profil se remplit au démarrage de HAL.").foregroundStyle(Palette.textePrincipal)
                }
            } else {
                Section("Toi") {
                    DatePicker("Date de naissance", selection: $naissance, in: ...Date.now, displayedComponents: .date)
                        .environment(\.locale, enFrancais)
                    Picker("Sexe", selection: $sexe) { options(LibellesHAL.sexes) }
                    Stepper("Taille : \(taille) cm", value: $taille, in: 100...250)
                }
                Section("Niveau") {
                    Picker("Musculation", selection: $niveauMusculation) { options(LibellesHAL.niveaux) }
                    Picker("Course à pied", selection: $niveauCourse) { options(LibellesHAL.niveaux) }
                }
                Section {
                    Picker("Moment préféré", selection: $moment) { options(LibellesHAL.moments) }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Jours sans sport").foregroundStyle(Palette.textePrincipal)
                            Spacer()
                            Text(joursEnClair).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            ForEach(1...7, id: \.self) { jour in
                                let sans = jours.contains(jour)
                                Button {
                                    if sans { jours.remove(jour) } else { jours.insert(jour) }
                                } label: {
                                    Text(String(Calendar.current.weekdaySymbolsFrancais[jour - 1].prefix(1)).uppercased())
                                        .texte(.corpsFort)
                                        .foregroundStyle(sans ? Palette.textePrincipal : Palette.texteSecondaire)
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                        .background(sans ? Categorie.alerte.voile : Palette.verreTeinte, in: Circle())
                                        .overlay(Circle().strokeBorder(sans ? Categorie.alerte.couleur : Palette.verreBord,
                                                                       lineWidth: sans ? 1 : 0.5))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Jamais le \(Calendar.current.weekdaySymbolsFrancais[jour - 1])")
                                .accessibilityAddTraits(sans ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Disponibilités")
                }
                Section("Alimentation") {
                    Toggle("Parler alimentation et compléments", isOn: $complements)
                    TextField("Régime à respecter", text: $regime)
                }
                Section {
                    Toggle("Laisser HAL décider", isOn: Binding { maximum == nil } set: { maximum = $0 ? nil : 4 })
                    if let valeur = maximum {
                        HStack {
                            Text("Séances par semaine au plus").foregroundStyle(Palette.textePrincipal)
                            Spacer()
                            Compteur(titre: "Max", valeur: Binding { Double(valeur) } set: { maximum = Int($0) },
                                     bornes: 1...14, unite: "max", compact: true)
                                .frame(width: 150)
                        }
                    }
                } header: {
                    Text("Réglages du plan")
                }
                Refus(texte: erreur)
                Section {
                    Button { Task { await enregistrer() } } label: {
                        HStack { Spacer(); if envoi { ProgressView() } else { Text("Enregistrer").bold() }; Spacer() }
                    }
                    .disabled(envoi)
                }
            }
        }
        .navigationTitle("Profil sportif")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, profil sportif")
        .task { await charger() }
    }

    private func options(_ liste: [(String, String)]) -> some View {
        ForEach(liste, id: \.0) { Text($0.1).tag($0.0) }
    }

    private func charger() async {
        defer { charge = true }
        guard let etat: EtatDemarrage = try? await foyer.demander("GET", "appli/demarrage") else {
            sansProfil = !foyer.connecte
            return
        }
        maximum = etat.seancesMaxSemaine
        guard let profil = etat.profil else {
            sansProfil = true
            return
        }
        naissance = profil.dateNaissance
        sexe = profil.sexe
        taille = profil.tailleCm
        niveauMusculation = profil.niveauMusculation
        niveauCourse = profil.niveauCourse
        moment = profil.momentPrefere ?? "indifferent"
        jours = Set(profil.joursSansSport ?? [])
        complements = profil.accordComplements ?? false
        regime = profil.regime ?? ""
    }

    private struct Maximum: Encodable { let valeur: Int? }

    private func enregistrer() async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        let profil = EnvoiProfil(dateNaissance: TexteHAL.jourISO(naissance), sexe: sexe, tailleCm: taille,
                                 niveauMusculation: niveauMusculation, niveauCourse: niveauCourse,
                                 momentPrefere: moment, joursSansSport: jours.sorted(),
                                 accordComplements: complements,
                                 regime: regime.trimmingCharacters(in: .whitespaces).isEmpty ? nil : regime)
        do {
            try await foyer.agir("PUT", "profil", corps: ClientAPI.corps(profil))
            try await foyer.agir("PUT", "appli/seances-max", corps: ClientAPI.corps(Maximum(valeur: maximum)))
            annoncer("Profil enregistré")
            fermer()
        } catch {
            erreur = raison(error)
        }
    }
}

extension EcranProfilSportif {
    /// « Dimanche », « Samedi, dimanche » ou « Aucun ».
    fileprivate var joursEnClair: String {
        guard !jours.isEmpty else { return "Aucun" }
        let noms = jours.sorted().map { Calendar.current.weekdaySymbolsFrancais[$0 - 1] }
        return noms.joined(separator: ", ").prefix(1).uppercased() + noms.joined(separator: ", ").dropFirst()
    }
}

private extension Calendar {
    /// Lundi d'abord, en français : « lundi », « mardi »…
    var weekdaySymbolsFrancais: [String] {
        ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
    }
}

// MARK: - 5.6 Limitations

/// EXO-6 à EXO-9 : une zone, un côté, une description, et les exercices qu'elle
/// interdit. C'est toi qui les déclares ; HAL peut seulement le proposer.
struct EcranLimitations: View {
    @Environment(Foyer.self) private var foyer
    @State private var limitations: [LimitationHAL]?
    @State private var erreur: String?
    @State private var nouvelle = false
    @State private var aRegler: LimitationHAL?

    var body: some View {
        FormulaireVerre {
            if let limitations {
                if limitations.isEmpty {
                    Section { Text("Aucune limitation.").foregroundStyle(Palette.texteSecondaire) }
                }
                ForEach(limitations) { limitation in
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background((limitation.active ?? true) ? Categorie.alerte.couleur : Palette.texteTertiaire,
                                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(limitation.libelle).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                                if let description = limitation.description, !description.isEmpty {
                                    Text(description.components(separatedBy: "<!-- complet -->")[0])
                                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                }
                            }
                            Spacer(minLength: 4)
                            Toggle("Active", isOn: Binding {
                                limitation.active ?? true
                            } set: { oui in
                                Task { await activer(limitation, oui) }
                            })
                            .labelsHidden()
                        }
                        let interdits = limitation.interdits ?? []
                        if !interdits.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("EXERCICES INTERDITS").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                                ForEach(interdits, id: \.code) { interdit in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(interdit.libelle ?? interdit.code).foregroundStyle(Palette.textePrincipal)
                                            if let motif = interdit.motif, !motif.isEmpty, motif != limitation.description {
                                                Text(motif).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        BoutonRond("xmark", libelle: "Ne plus interdire \(interdit.libelle ?? interdit.code)") {
                                            Task { await retirer(interdit, de: limitation) }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        Button("Interdire un autre exercice") { aRegler = limitation }
                            .buttonStyle(.hal(.verre, pleineLargeur: true))
                    }
                }
                Refus(texte: erreur)
                Section {
                    Button("Ajouter une limitation") { nouvelle = true }
                }
            } else if let erreur {
                Section { Text(erreur).foregroundStyle(Palette.texteSecondaire) }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Limitations")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, limitations")
        .task { await charger() }
        .sheet(isPresented: $nouvelle, onDismiss: { Task { await charger() } }) {
            NavigationStack { NouvelleLimitation() }.feuilleEnVerre()
        }
        .sheet(item: $aRegler, onDismiss: { Task { await charger() } }) { limitation in
            NavigationStack { ChoixDesInterdits(limitation: limitation) }.feuilleEnVerre()
        }
    }

    private func charger() async {
        do {
            limitations = try await foyer.demander("GET", "limitations")
            erreur = nil
        } catch {
            erreur = raison(error)
        }
    }

    private struct Activation: Encodable { let active: Bool }

    private struct Interdit: Encodable {
        let code: String
        let motif: String
    }

    /// Le × d'un exercice interdit : la liste renvoyée sans lui (EXO-8).
    private func retirer(_ interdit: LimitationHAL.Interdit, de limitation: LimitationHAL) async {
        let defaut = String((limitation.description ?? limitation.libelle).prefix(200))
        let restants = (limitation.interdits ?? []).filter { $0.code != interdit.code }
            .map { Interdit(code: $0.code, motif: $0.motif ?? defaut) }
        do {
            try await foyer.agir("PUT", "limitations/\(limitation.idLimitation)/interdits",
                                 corps: ClientAPI.corps(restants))
            await charger()
        } catch {
            erreur = raison(error)
        }
    }

    private func activer(_ limitation: LimitationHAL, _ oui: Bool) async {
        do {
            try await foyer.agir("PATCH", "limitations/\(limitation.idLimitation)",
                                 corps: ClientAPI.corps(Activation(active: oui)))
            await charger()
        } catch {
            erreur = raison(error)
        }
    }
}

private struct NouvelleLimitation: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var zone = "genou"
    @State private var cote = "gauche"
    @State private var description = ""
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            Section {
                Picker("Où", selection: $zone) { ForEach(LibellesHAL.zones, id: \.0) { Text($0.1).tag($0.0) } }
                Picker("De quel côté", selection: $cote) { ForEach(LibellesHAL.cotes, id: \.0) { Text($0.1).tag($0.0) } }
            }
            Section("Décris-la") {
                TextField("Ce qui fait mal, quand, et le geste que tu ne peux pas faire", text: $description,
                          axis: .vertical).lineLimit(3...6)
            }
            Refus(texte: erreur)
            Section {
                Button("Ajouter") { Task { await ajouter() } }
                    .disabled(description.trimmingCharacters(in: .whitespaces).count < 5)
            }
        }
        .navigationTitle("Nouvelle limitation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { fermer() } } }
    }

    private struct Corps: Encodable {
        let libelle: String
        let zone: String
        let cote: String
        let description: String
    }

    private func ajouter() async {
        let nomCote = cote == "deux" ? "des deux côtés" : cote
        do {
            try await foyer.agir("POST", "limitations", corps: ClientAPI.corps(Corps(
                libelle: "\(LibellesHAL.nom(zone, dans: LibellesHAL.zones)) (\(nomCote))", zone: zone,
                cote: cote, description: description)))
            fermer()
        } catch {
            erreur = raison(error)
        }
    }
}

/// EXO-8 : les exercices qu'une limitation interdit, choisis dans le catalogue.
private struct ChoixDesInterdits: View {
    let limitation: LimitationHAL
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var catalogue: [ExerciceCatalogue] = []
    @State private var choisis: Set<String> = []
    @State private var recherche = ""
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            Section {
                TextField("Chercher un exercice", text: $recherche)
            }
            Section {
                ForEach(filtres) { exercice in
                    Toggle(exercice.libelle, isOn: Binding {
                        choisis.contains(exercice.code)
                    } set: { oui in
                        if oui { choisis.insert(exercice.code) } else { choisis.remove(exercice.code) }
                    })
                }
            }
            Refus(texte: erreur)
        }
        .navigationTitle(limitation.libelle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Fermer") { fermer() } }
            ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { Task { await enregistrer() } } }
        }
        .task {
            choisis = Set((limitation.interdits ?? []).map(\.code))
            catalogue = (try? await foyer.demander("GET", "exercices")) ?? []
        }
    }

    private var filtres: [ExerciceCatalogue] {
        let mot = recherche.trimmingCharacters(in: .whitespaces).lowercased()
        let pris = catalogue.filter { choisis.contains($0.code) }
        let autres = catalogue.filter { !choisis.contains($0.code) && (mot.isEmpty || $0.libelle.lowercased().contains(mot)) }
        return pris + Array(autres.prefix(mot.isEmpty ? 30 : 80))
    }

    private struct Interdit: Encodable {
        let code: String
        let motif: String
    }

    private func enregistrer() async {
        let motif = String((limitation.description ?? limitation.libelle).prefix(200))
        do {
            try await foyer.agir("PUT", "limitations/\(limitation.idLimitation)/interdits",
                                 corps: ClientAPI.corps(choisis.sorted().map { Interdit(code: $0, motif: motif) }))
            fermer()
        } catch {
            erreur = raison(error)
        }
    }
}

// MARK: - 5.8 Mémoire de HAL

/// MEM-1, MEM-5 : les quatre étages que HAL relit à chaque appel. On corrige
/// n'importe lequel, et on remet une ancienne version : rien n'est effacé.
struct EcranMemoire: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var memoire: MemoireHAL?
    @State private var erreur: String?
    @State private var aCorriger: EtageACorriger?
    @State private var niveau = "semaine"
    @State private var versions: [VersionMemoire]?

    struct EtageACorriger: Identifiable {
        let niveau: String
        let titre: String
        let texte: String
        var id: String { niveau }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                Segmente(choix: [("semaine", "Semaine"), ("mois", "Mois"), ("trois", "3 mois"), ("globale", "Globale")],
                         selection: $niveau.animation(.smooth))
                if let memoire {
                    if niveau == "trois" {
                        troisMois(memoire.troisMois ?? [])
                    } else {
                        etage(memoire)
                        dernieresVersions
                    }
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Mémoire de HAL")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, mémoire de HAL")
        .task { await charger() }
        .task(id: niveau) { await chargerVersions() }
        .sheet(item: $aCorriger, onDismiss: { Task { await charger(); await chargerVersions() } }) { etage in
            NavigationStack { CorrigerMemoire(etage: etage) }.feuilleEnVerre()
        }
    }

    private var titre: String {
        switch niveau {
        case "semaine": "Cette semaine"
        case "mois": "Ce mois-ci"
        default: "Ce qui dure"
        }
    }

    private func contenu(_ memoire: MemoireHAL) -> MemoireHAL.Etage? {
        switch niveau {
        case "semaine": memoire.semaine
        case "mois": memoire.mois
        default: memoire.globale
        }
    }

    /// « Semaine du 12 octobre », « Octobre 2026 » ou « Ce qui dure ».
    private func entete(_ etage: MemoireHAL.Etage?) -> String {
        guard let periode = etage?.periode else { return titre }
        return niveau == "semaine"
            ? "Semaine du \(periode.formatted(.dateTime.day().month(.wide).locale(enFrancais)))"
            : periode.formatted(.dateTime.month(.wide).year().locale(enFrancais)).capitalized
    }

    private func etage(_ memoire: MemoireHAL) -> some View {
        let etage = contenu(memoire)
        let texte = etage?.texte ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(entete(etage)).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                Spacer()
                if let longueur = etage?.longueur, let limite = etage?.limite {
                    Text("\(EnFrancais.nombre(longueur)) / \(EnFrancais.nombre(limite))")
                        .texte(.legende).monospacedDigit().foregroundStyle(Palette.texteTertiaire)
                }
            }
            Text(texte.isEmpty ? "Vide pour l'instant." : texte)
                .texte(.corps)
                .foregroundStyle(texte.isEmpty ? Palette.texteSecondaire : Palette.textePrincipal)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(aide).texte(.legende).foregroundStyle(Palette.texteTertiaire)
            HStack(spacing: 10) {
                Button("Corriger") { aCorriger = EtageACorriger(niveau: niveau, titre: titre, texte: texte) }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                NavigationLink {
                    VersionsMemoire(niveau: niveau, titre: titre)
                } label: {
                    Text(versions.map { "Versions (\($0.count))" } ?? "Versions")
                }
                .buttonStyle(.hal(.verre, pleineLargeur: true))
            }
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte()
    }

    private var aide: String {
        switch niveau {
        case "semaine": "Ce que HAL retient au fil de la semaine. Versé dans le mois le lundi."
        case "mois": "Le résumé des semaines finies du mois."
        default: "Ce que HAL garde sur le long terme : tes habitudes, ce qui marche pour toi."
        }
    }

    /// MEM-5 : les trois dernières versions, à remettre d'un bouton.
    @ViewBuilder private var dernieresVersions: some View {
        if let versions, versions.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Text("DERNIÈRES VERSIONS").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                ForEach(versions.dropFirst().prefix(3)) { version in
                    HStack(spacing: 10) {
                        Text(Self.qui(version.auteur)).texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        if let quand = version.quand {
                            Text("\(Self.quel(quand)) \(EnFrancais.heure(quand))")
                                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                        Button("Remettre") { Task { await restaurer(version) } }
                            .buttonStyle(.hal(.verre))
                    }
                }
            }
            .padding(Espace.interne)
            .carte()
        }
    }

    /// « aujourd'hui », « hier » ou « lun. ».
    private static func quel(_ date: Date) -> String {
        let calendrier = Calendar.current
        if calendrier.isDateInToday(date) { return "aujourd'hui" }
        if calendrier.isDateInYesterday(date) { return "hier" }
        return EnFrancais.jourCourt(date).lowercased()
    }

    private static func qui(_ auteur: String?) -> String {
        switch auteur {
        case "coach": "HAL"
        case "utilisateur": "Toi"
        case "resume": "Résumé de la nuit"
        case "reprise": "Anciennes notes"
        default: auteur ?? "—"
        }
    }

    private func troisMois(_ archives: [MemoireHAL.Etage]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if archives.isEmpty {
                Text("Rien encore.").texte(.corps).foregroundStyle(Palette.texteSecondaire)
            }
            ForEach(archives, id: \.self) { archive in
                VStack(alignment: .leading, spacing: 4) {
                    if let periode = archive.periode {
                        Text(periode.formatted(.dateTime.month(.wide).year().locale(enFrancais)).capitalized)
                            .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    }
                    Text(archive.texte ?? "").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte()
    }

    private func charger() async {
        do {
            memoire = try await foyer.demander("GET", "coach/memoire")
            erreur = nil
        } catch {
            erreur = raison(error)
        }
    }

    private func chargerVersions() async {
        guard niveau != "trois" else { return }
        versions = nil
        versions = try? await foyer.demander("GET", "coach/memoire/\(niveau)/versions")
    }

    private func restaurer(_ version: VersionMemoire) async {
        do {
            try await foyer.agir("POST", "coach/memoire/versions/\(version.idMemoire)/restaurer")
            annoncer("Version remise en vigueur")
            await charger()
            await chargerVersions()
        } catch {
            erreur = raison(error)
        }
    }
}

private struct CorrigerMemoire: View {
    let etage: EcranMemoire.EtageACorriger
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var texte = ""
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            Section {
                TextEditor(text: $texte).frame(minHeight: 240)
            }
            Refus(texte: erreur)
        }
        .navigationTitle(etage.titre)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Fermer") { fermer() } }
            ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { Task { await enregistrer() } } }
        }
        .onAppear { texte = etage.texte }
    }

    private struct Corps: Encodable { let texte: String }

    private func enregistrer() async {
        do {
            try await foyer.agir("PUT", "coach/memoire/\(etage.niveau)", corps: ClientAPI.corps(Corps(texte: texte)))
            fermer()
        } catch {
            erreur = raison(error)
        }
    }
}

private struct VersionsMemoire: View {
    let niveau: String
    let titre: String
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var versions: [VersionMemoire]?
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            if let versions {
                if versions.isEmpty {
                    Section { Text("Aucune version.").foregroundStyle(Palette.texteSecondaire) }
                }
                ForEach(versions) { version in
                    Section {
                        Text(version.debut ?? "").font(.callout).foregroundStyle(Palette.textePrincipal)
                        Button("Remettre cette version") { Task { await restaurer(version) } }
                    } header: {
                        Text([version.quand?.formatted(date: .abbreviated, time: .shortened),
                              Self.auteur(version.auteur)].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                Refus(texte: erreur)
            } else if let erreur {
                Section { Text(erreur).foregroundStyle(Palette.texteSecondaire) }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle(titre)
        .navigationBarTitleDisplayMode(.inline)
        .task { await charger() }
    }

    static func auteur(_ code: String?) -> String? {
        switch code {
        case "coach": "écrite par HAL"
        case "utilisateur": "écrite par toi"
        case "resume": "résumé de la nuit"
        case "reprise": "reprise des anciennes notes"
        default: code
        }
    }

    private func charger() async {
        do {
            versions = try await foyer.demander("GET", "coach/memoire/\(niveau)/versions")
        } catch {
            erreur = raison(error)
        }
    }

    private func restaurer(_ version: VersionMemoire) async {
        do {
            try await foyer.agir("POST", "coach/memoire/versions/\(version.idMemoire)/restaurer")
            annoncer("Version remise en vigueur")
            await charger()
        } catch {
            erreur = raison(error)
        }
    }
}

// MARK: - 5.9 Mettre HAL en pause

/// PAU-1 : un motif libre, une date de fin si on la connaît. On la lève quand
/// on veut, ici ou depuis le bandeau de Sport.
struct EcranPause: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var pause: PauseHAL?
    @State private var charge = false
    @State private var motif = ""
    @State private var avecFin = true
    @State private var fin = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var erreur: String?

    private struct Reponse: Decodable, Sendable { let pause: PauseHAL? }

    private static let motifs = ["Examens", "Vacances", "Malade", "Blessure"]
    @State private var autreMotif = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                HStack(spacing: 12) {
                    Orbe(etat: .repos, taille: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pause == nil ? "HAL se met en retrait" : "HAL est en pause")
                            .texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                        Text(sousTitre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Espace.interne)
                .carte()

                if !charge {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else if pause != nil {
                    LigneErreur(texte: erreur)
                    Button("Reprendre maintenant") { Task { await lever() } }
                        .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                } else {
                    EnTeteGroupe(texte: "Motif")
                    Flux(espacement: 8) {
                        ForEach(Self.motifs, id: \.self) { choix in
                            PuceChoix(texte: choix, choisie: !autreMotif && motif == choix) {
                                autreMotif = false
                                motif = motif == choix ? "" : choix
                            }
                        }
                        PuceChoix(texte: "Autre", choisie: autreMotif) {
                            autreMotif.toggle()
                            motif = ""
                        }
                    }
                    if autreMotif {
                        TextField("Le motif, en quelques mots", text: $motif)
                            .texte(.corps).foregroundStyle(Palette.textePrincipal)
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                            .verreControle(Capsule(), interactif: false)
                    }

                    EnTeteGroupe(texte: "Fin")
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Pastille(icone: "calendar", couleur: Categorie.travail.couleur)
                            Text("Jusqu'au").texte(.corps).foregroundStyle(Palette.textePrincipal)
                            Spacer()
                            DatePicker("Jusqu'au", selection: $fin, in: Date.now..., displayedComponents: .date)
                                .labelsHidden()
                                .environment(\.locale, enFrancais)
                                .disabled(!avecFin)
                                .opacity(avecFin ? 1 : 0.4)
                        }
                        .padding(.horizontal, Espace.interne)
                        .padding(.vertical, 10)
                        Divider().overlay(Palette.verreBord)
                        HStack(spacing: 12) {
                            Pastille(icone: "clock", couleur: Palette.texteSecondaire)
                            Toggle("Je ne sais pas encore", isOn: Binding { !avecFin } set: { avecFin = !$0 })
                                .texte(.corps).foregroundStyle(Palette.textePrincipal)
                        }
                        .padding(.horizontal, Espace.interne)
                        .padding(.vertical, 10)
                    }
                    .carte(rayon: Rayon.controle)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("PENDANT LA PAUSE").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                        ForEach(Self.pendant, id: \.self) { ligne in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(Categorie.ia.couleur).frame(width: 6, height: 6)
                                Text(ligne).texte(.corps).foregroundStyle(Palette.textePrincipal)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(Espace.interne)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: Rayon.controle)

                    LigneErreur(texte: erreur)
                    Button("Mettre en pause") { Task { await mettre() } }
                        .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                }
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Pause")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, pause")
        .task { await charger() }
    }

    /// PAU-2 à PAU-6, en clair.
    private static let pendant = [
        "Aucune séance proposée, les proposées sont retirées",
        "Les séances validées restent, à toi de les garder",
        "Un récap un soir sur trois",
        "Séance libre et questions à HAL toujours possibles",
        "Au retour, une semaine de reprise",
    ]

    private var sousTitre: String {
        if let pause {
            let fin = pause.jusquAu.map { "jusqu'au \(EnFrancais.jour($0))" } ?? "sans date de fin"
            return [pause.motif, fin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return "Maladie, vacances, semaine d'examens."
    }

    private func charger() async {
        defer { charge = true }
        if let lu: Reponse = try? await foyer.demander("GET", "coach/pause") { pause = lu.pause }
    }

    private struct Corps: Encodable {
        let motif: String?
        let fin: String?
    }

    private func mettre() async {
        erreur = nil
        do {
            try await foyer.agir("POST", "coach/pause", corps: ClientAPI.corps(Corps(
                motif: motif.trimmingCharacters(in: .whitespaces).isEmpty ? nil : motif,
                fin: avecFin ? TexteHAL.jourISO(fin) : nil)))
            annoncer("HAL est en pause")
            await charger()
        } catch {
            erreur = raison(error)
        }
    }

    private func lever() async {
        erreur = nil
        do {
            try await foyer.agir("DELETE", "coach/pause")
            annoncer("Pause levée : HAL prépare la reprise")
            pause = nil
        } catch {
            erreur = raison(error)
        }
    }
}

// MARK: - Repartir de zéro (DEM-5)

/// Reprendre le démarrage (DEM-4), ou tout effacer et recommencer (DEM-5).
struct EcranDemarrageReglages: View {
    @Environment(Foyer.self) private var foyer
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.annoncer) private var annoncer
    @State private var confirmer = false
    @State private var garderSante = true
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            Section {
                Button("Reprendre le démarrage") { conversation.demarrageOuvert = true }
            }
            Section {
                Toggle("Garder les données de la montre", isOn: $garderSante)
                Button("Repartir de zéro", role: .destructive) { confirmer = true }
            } footer: {
                Text("Efface tout ce que HAL sait et a fait pour toi : profil, limitations, lieux, objectifs, plans, séances de HAL et séances libres, mesures, mémoire, échanges. Ton compte et le reste du planning restent.")
            }
            Refus(texte: erreur)
        }
        .navigationTitle("Démarrage de HAL")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Tout effacer et recommencer ?", isPresented: $confirmer, titleVisibility: .visible) {
            Button("Tout effacer", role: .destructive) { Task { await repartir() } }
        } message: {
            Text("C'est définitif.")
        }
    }

    private func repartir() async {
        erreur = nil
        do {
            try await foyer.agir("DELETE", "coach/donnees?garder_sante=\(garderSante)")
            annoncer("HAL repart de zéro")
            conversation.demarrageOuvert = true
        } catch {
            erreur = raison(error)
        }
    }
}
