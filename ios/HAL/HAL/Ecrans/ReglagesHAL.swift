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
                    ForEach(1...7, id: \.self) { jour in
                        Toggle("Jamais le \(Calendar.current.weekdaySymbolsFrancais[jour - 1])", isOn: Binding {
                            jours.contains(jour)
                        } set: { oui in
                            if oui { jours.insert(jour) } else { jours.remove(jour) }
                        })
                    }
                    Picker("Au plus par semaine", selection: $maximum) {
                        Text("HAL décide").tag(Int?.none)
                        ForEach(1...14, id: \.self) { n in Text("\(n) séances").tag(Int?.some(n)) }
                    }
                } header: {
                    Text("Disponibilités")
                } footer: {
                    Text("Le maximum borne ce que HAL propose (PLN-14). Sans maximum, il décide selon ta forme et ton emploi du temps.")
                }
                Section("Alimentation") {
                    Toggle("Me parler de compléments", isOn: $complements)
                    TextField("Régime à respecter", text: $regime)
                }
                Refus(texte: erreur)
                Section {
                    Button { Task { await enregistrer() } } label: {
                        HStack { Spacer(); if envoi { ProgressView() } else { Text("Enregistrer").bold() }; Spacer() }
                    }
                    .disabled(envoi)
                } footer: {
                    Text("Le poids n'est pas dans le profil : c'est une mesure, dans Sport.")
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(limitation.libelle).bold().foregroundStyle(Palette.textePrincipal)
                            if let description = limitation.description, !description.isEmpty {
                                Text(description.components(separatedBy: "<!-- complet -->")[0])
                                    .font(.footnote).foregroundStyle(Palette.texteSecondaire)
                            }
                        }
                        Toggle("Active", isOn: Binding {
                            limitation.active ?? true
                        } set: { oui in
                            Task { await activer(limitation, oui) }
                        })
                        Button {
                            aRegler = limitation
                        } label: {
                            LabeledContent("Exercices interdits", value: "\(limitation.interdits?.count ?? 0)")
                        }
                        ForEach(limitation.interdits ?? [], id: \.code) { interdit in
                            Text(interdit.libelle ?? interdit.code).font(.footnote).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                }
                Refus(texte: erreur)
                Section {
                    Button("Ajouter une limitation") { nouvelle = true }
                } footer: {
                    Text("Une limitation désactivée reste notée, mais ses exercices redeviennent possibles.")
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

// MARK: - 5.7 Lieux de sport

/// LIE-4 : les lieux de chaque discipline, rangés par préférence.
struct EcranLieux: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var possibles: [LieuPossible] = []
    @State private var choisis: [String: [Int]] = [:]
    @State private var charge = false
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            if !charge {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            ForEach(LibellesHAL.disciplines, id: \.0) { discipline in
                Section(discipline.1) {
                    ForEach(possibles) { lieu in
                        let rang = choisis[discipline.0]?.firstIndex(of: lieu.idLieu)
                        Button { basculer(lieu.idLieu, discipline.0) } label: {
                            HStack {
                                Text(lieu.libelle).foregroundStyle(Palette.textePrincipal)
                                Spacer()
                                if let rang {
                                    Text("\(rang + 1)").bold().foregroundStyle(Palette.texteSurAccent)
                                        .frame(width: 24, height: 24).background(Categorie.ia.couleur, in: Circle())
                                }
                            }
                        }
                    }
                }
            }
            Refus(texte: erreur)
            Section {
                Button("Enregistrer") { Task { await enregistrer() } }.frame(maxWidth: .infinity)
            } footer: {
                Text("Touche les lieux dans ton ordre de préférence. HAL prend le premier quand il n'a pas de raison d'en choisir un autre (LIE-2).")
            }
        }
        .navigationTitle("Lieux de sport")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, lieux de sport")
        .task { await charger() }
    }

    private func basculer(_ lieu: Int, _ discipline: String) {
        var liste = choisis[discipline] ?? []
        if let rang = liste.firstIndex(of: lieu) { liste.remove(at: rang) } else { liste.append(lieu) }
        choisis[discipline] = liste
    }

    private func charger() async {
        defer { charge = true }
        guard let etat: EtatDemarrage = try? await foyer.demander("GET", "appli/demarrage") else { return }
        possibles = etat.lieuxPossibles
        for discipline in LibellesHAL.disciplines.map(\.0) {
            choisis[discipline] = etat.lieux.filter { $0.discipline == discipline }.sorted { $0.rang < $1.rang }.map(\.idLieu)
        }
    }

    private func enregistrer() async {
        erreur = nil
        do {
            for discipline in LibellesHAL.disciplines.map(\.0) {
                try await foyer.agir("PUT", "disciplines/\(discipline)/lieux",
                                     corps: ClientAPI.corps(choisis[discipline] ?? []))
            }
            annoncer("Lieux enregistrés")
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
    @State private var memoire: MemoireHAL?
    @State private var erreur: String?
    @State private var aCorriger: EtageACorriger?

    struct EtageACorriger: Identifiable {
        let niveau: String
        let titre: String
        let texte: String
        var id: String { niveau }
    }

    var body: some View {
        FormulaireVerre {
            if let memoire {
                etage("semaine", "Cette semaine", memoire.semaine,
                      "Ce que HAL retient au fil de la semaine. Versé dans le mois le lundi.")
                etage("mois", "Ce mois-ci", memoire.mois, "Le résumé des semaines finies du mois.")
                Section {
                    if (memoire.troisMois ?? []).isEmpty {
                        Text("Rien encore.").foregroundStyle(Palette.texteSecondaire)
                    }
                    ForEach(memoire.troisMois ?? [], id: \.self) { archive in
                        VStack(alignment: .leading, spacing: 4) {
                            if let periode = archive.periode {
                                Text(periode.formatted(.dateTime.month(.wide).year().locale(enFrancais)).capitalized)
                                    .bold().foregroundStyle(Palette.textePrincipal)
                            }
                            Text(archive.texte ?? "").font(.footnote).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                } header: {
                    Text("Les trois derniers mois")
                } footer: {
                    Text("Résumés chaque nuit. Ils ne se corrigent pas ici : corrige plutôt la mémoire globale.")
                }
                etage("globale", "Ce qui dure", memoire.globale,
                      "Ce que HAL garde sur le long terme : tes habitudes, ce qui marche pour toi.")
                Refus(texte: erreur)
            } else if let erreur {
                Section { Text(erreur).foregroundStyle(Palette.texteSecondaire) }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Mémoire de HAL")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, mémoire de HAL")
        .task { await charger() }
        .sheet(item: $aCorriger, onDismiss: { Task { await charger() } }) { etage in
            NavigationStack { CorrigerMemoire(etage: etage) }.feuilleEnVerre()
        }
    }

    @ViewBuilder
    private func etage(_ niveau: String, _ titre: String, _ contenu: MemoireHAL.Etage?, _ aide: String) -> some View {
        Section {
            let texte = contenu?.texte ?? ""
            Text(texte.isEmpty ? "Vide pour l'instant." : texte)
                .font(.callout)
                .foregroundStyle(texte.isEmpty ? Palette.texteSecondaire : Palette.textePrincipal)
                .textSelection(.enabled)
            if let longueur = contenu?.longueur, let limite = contenu?.limite {
                Text("\(longueur) sur \(limite) caractères").font(.footnote).foregroundStyle(Palette.texteTertiaire)
            }
            Button("Corriger") { aCorriger = EtageACorriger(niveau: niveau, titre: titre, texte: texte) }
            NavigationLink("Versions") { VersionsMemoire(niveau: niveau, titre: titre) }
        } header: {
            Text(titre)
        } footer: {
            Text(aide)
        }
    }

    private func charger() async {
        do {
            memoire = try await foyer.demander("GET", "coach/memoire")
            erreur = nil
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
            } footer: {
                Text("L'ancienne version reste : tu pourras la remettre.")
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
    @State private var avecFin = false
    @State private var fin = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var erreur: String?

    private struct Reponse: Decodable, Sendable { let pause: PauseHAL? }

    var body: some View {
        FormulaireVerre {
            if !charge {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let pause {
                Section {
                    LabeledContent("Depuis", value: pause.depuis?.formatted(date: .abbreviated, time: .omitted) ?? "")
                    LabeledContent("Jusqu'au", value: pause.jusquAu?.formatted(date: .abbreviated, time: .omitted) ?? "sans date")
                    if let motif = pause.motif, !motif.isEmpty { LabeledContent("Motif", value: motif) }
                } header: {
                    Text("HAL est en pause")
                }
                Refus(texte: erreur)
                Section {
                    Button("Reprendre maintenant") { Task { await lever() } }.frame(maxWidth: .infinity)
                } footer: {
                    Text("HAL relit ce qui s'est passé et te propose une semaine de reprise, par message.")
                }
            } else {
                Section {
                    TextField("Motif (vacances, examens, blessure…)", text: $motif)
                    Toggle("Je connais la date de fin", isOn: $avecFin)
                    if avecFin {
                        DatePicker("Fin", selection: $fin, in: Date.now..., displayedComponents: .date)
                            .environment(\.locale, enFrancais)
                    }
                } footer: {
                    Text("Pendant la pause, HAL ne propose aucune séance. Les séances proposées sont retirées ; les validées restent, à toi de les garder ou non. Tu peux toujours lui écrire, et faire des séances libres.")
                }
                Refus(texte: erreur)
                Section {
                    Button("Mettre HAL en pause") { Task { await mettre() } }.frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Pause")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, pause")
        .task { await charger() }
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
            } footer: {
                Text("Il repart de là où tu t'étais arrêté. Ce qui est déjà rempli est sauté, et chaque ligne du récapitulatif se corrige.")
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
