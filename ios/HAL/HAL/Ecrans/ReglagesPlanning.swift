import SwiftUI
import UIKit

// Réglages, groupe « Planning » (5.3, 5.4, 5.12, 5.17) : les calendriers qu'on
// suit, ceux auxquels on s'abonne, et l'Historique. Ce que le bot faisait par
// « /lien », « /groupe », « /ecarter », « /arreter », « /calendrier » et
// « /pourquoi » se fait ici.

private let enFrancais = Locale(identifier: "fr_FR")

private func motifDe(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

/// Une ligne d'erreur dans un formulaire : le motif du serveur, tel quel (APP-5).
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

/// Ce qu'un écran de réglage dit en démonstration.
private struct SansServeur: View {
    let texte: String

    var body: some View {
        Section {
            Label(texte, systemImage: "wifi.slash").foregroundStyle(Palette.texteSecondaire)
        }
    }
}

/// « Cours », « Travail », « Perso » : ce qu'est un calendrier suivi.
enum NatureCalendrier: String, CaseIterable, Identifiable {
    case cours, travail, perso

    var id: String { rawValue }

    var libelle: String {
        switch self {
        case .cours: "Cours"
        case .travail: "Travail"
        case .perso: "Perso"
        }
    }

    var detail: String {
        switch self {
        case .cours: "Un emploi du temps de fac ou d'école, comme celui de l'ADE. Deux cours ne se chevauchent pas : un chevauchement te sera demandé."
        case .travail: "Un planning de travail publié en lien. Les services ne se chevauchent pas non plus."
        case .perso: "Ton agenda : rendez-vous, sorties. HAL et le ménage s'organisent autour, sans conflit."
        }
    }

    var icone: String {
        switch self {
        case .cours: "graduationcap"
        case .travail: "briefcase"
        case .perso: "calendar"
        }
    }

    var categorie: Categorie {
        switch self {
        case .cours: .cours
        case .travail: .travail
        case .perso: .perso
        }
    }

    init(_ texte: String) { self = NatureCalendrier(rawValue: texte) ?? .perso }
}

/// « jeu. 15 oct. · 10:00 – 12:00 ».
private func moment(_ evenement: EvenementLu) -> String {
    let jour = evenement.debut.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(enFrancais))
    if evenement.journeeEntiere == true { return jour + " · journée" }
    var heure = evenement.debut.formatted(date: .omitted, time: .shortened)
    if let fin = evenement.fin { heure += " – " + fin.formatted(date: .omitted, time: .shortened) }
    return "\(jour) · \(heure)"
}

/// Un événement d'un calendrier : quand, quoi, où.
private struct LigneEvenementLu: View {
    let evenement: EvenementLu
    let categorie: Categorie

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(categorie.couleur).frame(width: 7, height: 7).padding(.top, 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(evenement.titre).foregroundStyle(Palette.textePrincipal).lineLimit(2)
                Text([moment(evenement), evenement.lieu].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Palette.texteSecondaire)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 5.3 Calendriers à suivre

/// Les flux lus pour le foyer et leur état (COL-9, COL-14). Toucher un
/// calendrier ouvre ses réglages : groupe de TD, UE écartées, lien, arrêt.
struct EcranCalendriersSuivis: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var calendriers: [CalendrierSuivi]?
    @State private var erreur: String?
    @State private var ajout = false
    @State private var collecte = false
    @State private var ecartAFaire: CalendrierSuivi?
    @State private var nouvelleUE = ""

    var body: some View {
        FormulaireVerre {
            if !foyer.connecte {
                SansServeur(texte: "Connecte-toi à ton serveur pour suivre tes calendriers.")
            } else if let calendriers {
                let miens = calendriers.filter { $0.pour == foyer.moi.id }
                let autres = calendriers.filter { $0.pour != foyer.moi.id }
                Section {
                    if miens.isEmpty {
                        Text("Aucun pour l'instant. Colle le lien de ta fac, de ton travail ou de ton agenda.")
                            .foregroundStyle(Palette.texteSecondaire)
                    }
                    ForEach(miens) { ligne($0) }
                } header: {
                    Text("Les tiens")
                }
                ForEach(parMembre(autres)) { groupe in
                    Section("Ceux de \(groupe.nom)") {
                        ForEach(groupe.calendriers) { ligne($0) }
                    }
                }
                ForEach(miens.filter { $0.ade && $0.active }) { fac($0) }
                Section {
                    HStack(spacing: 10) {
                        Button(collecte ? "Collecte…" : "Collecter maintenant") { Task { await collecter(miens) } }
                            .buttonStyle(.hal(.verre, pleineLargeur: true))
                            .disabled(collecte || !miens.contains { $0.active && $0.lienDonne })
                        Button("Ajouter un calendrier") { ajout = true }
                            .buttonStyle(.hal(.verre, pleineLargeur: true))
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else if let erreur {
                LigneRefus(texte: erreur)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Calendriers à suivre")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, calendriers à suivre")
        .task { await charger() }
        .refreshable { await charger() }
        .sheet(isPresented: $ajout) {
            NavigationStack { FormulaireCalendrier { await charger() } }.feuilleEnVerre()
        }
        .alert("Écarter un cours", isPresented: Binding { ecartAFaire != nil } set: { if !$0 { ecartAFaire = nil } }) {
            TextField("Traitement d'images", text: $nouvelleUE)
            Button("Écarter") {
                if let calendrier = ecartAFaire {
                    let propre = nouvelleUE.trimmingCharacters(in: .whitespaces)
                    if !propre.isEmpty {
                        Task { await regler(calendrier, Reglage(coursEcartes: calendrier.coursEcartes + [propre])) }
                    }
                }
                nouvelleUE = ""
            }
            Button("Annuler", role: .cancel) { nouvelleUE = "" }
        } message: {
            Text("Un extrait du nom suffit.")
        }
    }

    /// 5.3 : le groupe de TD et les UE écartées d'un calendrier de la fac, sous la main.
    private func fac(_ calendrier: CalendrierSuivi) -> some View {
        Section {
            HStack {
                Text("Groupe de TD").foregroundStyle(Palette.textePrincipal)
                Spacer()
                ForEach(1...3, id: \.self) { numero in
                    let choisi = calendrier.groupe == numero
                    Button {
                        Task { await regler(calendrier, Reglage(groupe: choisi ? 0 : numero)) }
                    } label: {
                        Text("\(numero)").texte(.corpsFort)
                            .foregroundStyle(Palette.textePrincipal)
                            .frame(width: 34, height: 34)
                            .background(choisi ? Categorie.ia.voile : Palette.verreTeinte, in: Circle())
                            .overlay(Circle().strokeBorder(choisi ? Categorie.ia.couleur : Palette.verreBord, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Groupe \(numero)")
                    .accessibilityAddTraits(choisi ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("UE AU CHOIX QUE JE NE SUIS PAS").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                Flux(espacement: 8) {
                    ForEach(calendrier.coursEcartes, id: \.self) { cours in
                        PuceChoix(texte: "\(cours) ×", choisie: false) {
                            Task { await regler(calendrier, Reglage(coursEcartes: calendrier.coursEcartes.filter { $0 != cours })) }
                        }
                        .accessibilityLabel("Reprendre \(cours)")
                    }
                    PuceChoix(texte: "+ Écarter un cours", choisie: false) { ecartAFaire = calendrier }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(calendrier.libelle)
        }
    }

    private struct Reglage: Encodable {
        var groupe: Int? = nil
        var coursEcartes: [String]? = nil
    }

    private func regler(_ calendrier: CalendrierSuivi, _ reglage: Reglage) async {
        do {
            let rendu: CalendrierEtCollecte = try await foyer.demander(
                "PATCH", "appli/calendriers/\(calendrier.id)", corps: ClientAPI.corps(reglage))
            annoncer(rendu.collecte?.enClair ?? "Filtre changé")
            await charger()
            await foyer.charger()
        } catch {
            erreur = motifDe(error)
        }
    }

    /// CNX-5 : forcer une collecte ne passe que par le réseau privé ; ailleurs,
    /// le serveur refuse et son motif s'affiche tel quel.
    private func collecter(_ miens: [CalendrierSuivi]) async {
        collecte = true
        defer { collecte = false }
        erreur = nil
        var lus = 0
        for calendrier in miens where calendrier.active && calendrier.lienDonne {
            do {
                try await foyer.agir("POST", "sources/\(calendrier.code)/collecter")
                lus += 1
            } catch {
                erreur = motifDe(error)
            }
        }
        if lus > 0 { annoncer(lus == 1 ? "Calendrier relu" : "\(lus) calendriers relus") }
        await charger()
    }

    private struct DeMembre: Identifiable {
        let nom: String
        let calendriers: [CalendrierSuivi]
        var id: String { nom }
    }

    /// Les calendriers des autres membres, rangés par prénom.
    private func parMembre(_ liste: [CalendrierSuivi]) -> [DeMembre] {
        let groupes = Dictionary(grouping: liste, by: \.pourNom)
        return groupes.keys.sorted().map { DeMembre(nom: $0, calendriers: groupes[$0] ?? []) }
    }

    private func ligne(_ calendrier: CalendrierSuivi) -> some View {
        NavigationLink {
            EcranCalendrierSuivi(calendrier: calendrier) { await charger() }
        } label: {
            HStack(spacing: 12) {
                let nature = NatureCalendrier(calendrier.nature)
                Pastille(icone: nature.icone, couleur: calendrier.active ? nature.categorie.couleur : Palette.texteTertiaire)
                VStack(alignment: .leading, spacing: 2) {
                    Text(calendrier.libelle).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                    Text(calendrier.etatEnClair + (calendrier.active && calendrier.aVenir > 0
                                                   ? " · \(calendrier.aVenir) à venir" : ""))
                        .font(.footnote)
                        .foregroundStyle(calendrier.enPanne ? Categorie.alerte.couleur : Palette.texteSecondaire)
                }
                Spacer(minLength: 4)
                badge(calendrier)
            }
        }
    }

    /// OK, Inactif ou En panne, d'un coup d'œil (COL-9).
    private func badge(_ calendrier: CalendrierSuivi) -> some View {
        let (texte, couleur): (String, Color) =
            !calendrier.active || !calendrier.lienDonne ? ("Inactif", Palette.texteSecondaire)
            : calendrier.enPanne ? ("En panne", Categorie.alerte.couleur)
            : ("OK", Categorie.sport.couleur)
        return Text(texte).texte(.legende).fontWeight(.semibold)
            .foregroundStyle(couleur)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(couleur.opacity(0.18), in: Capsule())
    }

    private func charger() async {
        guard foyer.connecte else { return }
        do {
            calendriers = try await foyer.demander("GET", "appli/calendriers")
            erreur = nil
        } catch {
            erreur = motifDe(error)
        }
    }
}

/// Un calendrier suivi : ce qu'il donne, son lien, son filtre, et l'arrêter (COL-17, COL-21).
struct EcranCalendrierSuivi: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @Environment(\.dismiss) private var fermer
    @State private var calendrier: CalendrierSuivi
    @State private var nom: String
    @State private var nouvelleUE = ""
    @State private var envoi = false
    @State private var erreur: String?
    @State private var lien = false
    @State private var arret = false
    let apres: () async -> Void

    init(calendrier: CalendrierSuivi, apres: @escaping () async -> Void) {
        _calendrier = State(initialValue: calendrier)
        _nom = State(initialValue: calendrier.libelle)
        self.apres = apres
    }

    var body: some View {
        let nature = NatureCalendrier(calendrier.nature)
        FormulaireVerre {
            Section {
                LabeledContent("À qui", value: calendrier.pourNom)
                LabeledContent("Ce que c'est", value: nature.libelle)
                LabeledContent("État", value: calendrier.etatEnClair)
                if calendrier.active {
                    LabeledContent("À venir", value: "\(calendrier.aVenir) événement\(calendrier.aVenir > 1 ? "s" : "")")
                }
            }
            if let prochain = calendrier.prochain, calendrier.active {
                Section("Prochain") {
                    LigneEvenementLu(evenement: prochain, categorie: nature.categorie)
                }
            }
            Section {
                TextField("Nom", text: $nom)
                    .onSubmit { Task { await renommer() } }
                if nom != calendrier.libelle, !nom.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Renommer") { Task { await renommer() } }.disabled(envoi)
                }
            } header: {
                Text("Nom")
            }
            if calendrier.ade && calendrier.active {
                Section {
                    Picker("Groupe de TD", selection: Binding {
                        calendrier.groupe ?? 0
                    } set: { groupe in
                        Task { await regler(Reglage(groupe: groupe), annonce: groupe == 0 ? "Tous les groupes" : "Groupe \(groupe)") }
                    }) {
                        Text("Tous").tag(0)
                        ForEach(1...9, id: \.self) { Text("Groupe \($0)").tag($0) }
                    }
                    .disabled(envoi)
                } header: {
                    Text("Filtre")
                }
                Section {
                    ForEach(calendrier.coursEcartes, id: \.self) { cours in
                        Text(cours).foregroundStyle(Palette.textePrincipal)
                    }
                    .onDelete { rangs in
                        var liste = calendrier.coursEcartes
                        liste.remove(atOffsets: rangs)
                        Task { await regler(Reglage(coursEcartes: liste), annonce: "Cours repris") }
                    }
                    HStack {
                        TextField("Traitement d'images", text: $nouvelleUE)
                            .onSubmit { ecarter() }
                        Button("Écarter") { ecarter() }
                            .disabled(nouvelleUE.trimmingCharacters(in: .whitespaces).isEmpty || envoi)
                    }
                } header: {
                    Text("UE que tu ne suis pas")
                } footer: {
                    Text("Un extrait du nom suffit.")
                }
            }
            LigneRefus(texte: erreur)
            Section {
                Button(calendrier.lienDonne ? "Changer le lien" : "Donner le lien") { lien = true }
                if calendrier.active {
                    Button("Ne plus suivre", role: .destructive) { arret = true }
                } else if calendrier.lienDonne {
                    Button("Suivre de nouveau") { Task { await reprendre() } }.disabled(envoi)
                }
            }
        }
        .navigationTitle(calendrier.libelle)
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, calendrier « \(calendrier.libelle) »")
        .overlay { if envoi { ProgressView().padding(20).carte(rayon: Rayon.controle) } }
        .sheet(isPresented: $lien) {
            NavigationStack {
                FormulaireCalendrier(existant: calendrier) {
                    await apres()
                    if let lu = try? await relire() { calendrier = lu }
                }
            }
            .feuilleEnVerre()
        }
        .confirmationDialog("Ne plus suivre « \(calendrier.libelle) » ?", isPresented: $arret,
                            titleVisibility: .visible) {
            Button("Ne plus suivre", role: .destructive) { Task { await arreter() } }
        }
    }

    private struct Reglage: Encodable {
        var libelle: String? = nil
        var groupe: Int? = nil
        var coursEcartes: [String]? = nil
    }

    private func relire() async throws -> CalendrierSuivi? {
        let tous: [CalendrierSuivi] = try await foyer.demander("GET", "appli/calendriers")
        return tous.first { $0.id == calendrier.id }
    }

    private func ecarter() {
        let propre = nouvelleUE.trimmingCharacters(in: .whitespaces)
        guard !propre.isEmpty else { return }
        nouvelleUE = ""
        Task { await regler(Reglage(coursEcartes: calendrier.coursEcartes + [propre]), annonce: "« \(propre) » écarté") }
    }

    private func renommer() async {
        let propre = nom.trimmingCharacters(in: .whitespaces)
        guard !propre.isEmpty, propre != calendrier.libelle else { return }
        await regler(Reglage(libelle: propre), annonce: "Calendrier renommé")
    }

    private func regler(_ reglage: Reglage, annonce: String) async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            let rendu: CalendrierEtCollecte = try await foyer.demander(
                "PATCH", "appli/calendriers/\(calendrier.id)", corps: ClientAPI.corps(reglage))
            calendrier = rendu.calendrier
            nom = rendu.calendrier.libelle
            annoncer([annonce, rendu.collecte?.enClair].compactMap { $0 }.joined(separator: " · "))
            await apres()
            await foyer.charger()
        } catch {
            erreur = motifDe(error)
        }
    }

    private func arreter() async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            let rendu: ArretDeCalendrier = try await foyer.demander("POST", "appli/calendriers/\(calendrier.id)/arreter")
            calendrier = rendu.calendrier
            annoncer(rendu.retirees > 0 ? "Plus suivi · \(rendu.retirees) à venir retirés" : "Plus suivi")
            await apres()
            await foyer.charger()
        } catch {
            erreur = motifDe(error)
        }
    }

    private func reprendre() async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            let rendu: CalendrierEtCollecte = try await foyer.demander("POST", "appli/calendriers/\(calendrier.id)/reprendre")
            calendrier = rendu.calendrier
            annoncer("Suivi de nouveau · " + (rendu.collecte?.enClair ?? ""))
            await apres()
            await foyer.charger()
        } catch {
            erreur = motifDe(error)
        }
    }
}

// MARK: - 5.4 Ajouter un calendrier

/// COL-7 : coller le lien, le vérifier, dire ce que c'est et à qui. Le lien
/// n'est enregistré qu'une fois lu : l'écran montre ce qu'il donne d'abord.
///
/// Avec `existant`, le même écran donne ou change le lien d'un calendrier suivi.
struct FormulaireCalendrier: View {
    var existant: CalendrierSuivi? = nil
    var apres: (() async -> Void)? = nil
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var url = ""
    @State private var nature: NatureCalendrier = .cours
    @State private var pour: Int?
    @State private var libelle = ""
    @State private var essai: EssaiLien?
    @State private var essaye = ""
    @State private var verification = false
    @State private var envoi = false
    @State private var erreur: String?

    init(existant: CalendrierSuivi? = nil, apres: (() async -> Void)? = nil) {
        self.existant = existant
        self.apres = apres
        if let existant { _nature = State(initialValue: NatureCalendrier(existant.nature)) }
    }

    private var propre: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// L'essai vaut pour le lien tel qu'il était : le modifier oblige à revérifier.
    private var verifie: Bool { essai != nil && essaye == propre }

    var body: some View {
        FormulaireVerre {
            if !foyer.connecte {
                SansServeur(texte: "Connecte-toi à ton serveur pour ajouter un calendrier.")
            } else {
                Section {
                    TextField("https://…  ou  webcal://…", text: $url, axis: .vertical)
                        .lineLimit(1...4)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    PasteButton(payloadType: String.self) { textes in
                        guard let colle = textes.first else { return }
                        Task { @MainActor in url = colle }
                    }
                } header: {
                    Text("Le lien")
                } footer: {
                    Text("Dans Calendrier sur Mac ou iCloud.com : partager le calendrier, « Calendrier public », puis copier le lien. Dans Google Agenda : « Adresse secrète au format iCal ». Sur l'ADE : exporter, puis copier l'URL.")
                }
                if existant == nil {
                    Section {
                        Picker("Ce que c'est", selection: $nature) {
                            ForEach(NatureCalendrier.allCases) { Text($0.libelle).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(nature.detail).font(.footnote).foregroundStyle(Palette.texteSecondaire)
                        if foyer.membres.count > 1 {
                            Picker("À qui", selection: $pour) {
                                Text("À moi").tag(Int?.none)
                                ForEach(foyer.membres.filter { $0.id != foyer.moi.id }) {
                                    Text("À \($0.nom)").tag(Int?.some($0.id))
                                }
                            }
                        }
                    } header: {
                        Text("Ce que c'est, et à qui")
                    }
                }
                Section {
                    Button {
                        Task { await verifier() }
                    } label: {
                        HStack {
                            Text("Vérifier le lien")
                            Spacer()
                            if verification { ProgressView() }
                            else if verifie { Image(systemName: "checkmark.circle.fill").foregroundStyle(Categorie.sport.couleur) }
                        }
                    }
                    .disabled(propre.count < 8 || verification)
                    if let essai, verifie {
                        if essai.prochains.isEmpty {
                            Text("Le lien répond, mais rien n'est prévu dans les deux mois.")
                                .foregroundStyle(Palette.texteSecondaire)
                        } else {
                            ForEach(essai.prochains, id: \.self) {
                                LigneEvenementLu(evenement: $0, categorie: nature.categorie)
                            }
                        }
                    }
                } footer: {
                    if let essai, verifie {
                        Text("\(essai.aVenir) événement\(essai.aVenir > 1 ? "s" : "") dans les deux mois.")
                    }
                }
                if existant == nil {
                    Section("Nom") {
                        TextField(nomParDefaut, text: $libelle)
                    }
                }
                LigneRefus(texte: erreur)
                Section {
                    Button {
                        Task { await enregistrer() }
                    } label: {
                        HStack {
                            Spacer()
                            if envoi { ProgressView() } else {
                                Text(existant == nil ? "Suivre ce calendrier" : "Enregistrer le lien").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!verifie || envoi)
                }
            }
        }
        .navigationTitle(existant == nil ? "Ajouter un calendrier" : "Lien de « \(existant?.libelle ?? "") »")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fermer", systemImage: "xmark") { fermer() }
            }
        }
        .onChange(of: nature) { essai = nil }
    }

    private var nomParDefaut: String {
        let qui = foyer.membres.first { $0.id == pour }?.nom ?? foyer.moi.nom
        switch nature {
        case .cours: return "Cours de \(qui)"
        case .travail: return "Travail de \(qui)"
        case .perso: return "Calendrier de \(qui)"
        }
    }

    private struct Essai: Encodable {
        let url: String
        let nature: String
    }

    private func verifier() async {
        verification = true
        erreur = nil
        defer { verification = false }
        let lien = propre
        do {
            essai = try await foyer.demander("POST", "appli/calendriers/essai",
                                             corps: ClientAPI.corps(Essai(url: lien, nature: nature.rawValue)))
            essaye = lien
        } catch {
            essai = nil
            erreur = motifDe(error)
        }
    }

    private struct Nouveau: Encodable {
        let url: String
        let nature: String
        let pour: Int?
        let libelle: String?
    }

    private struct Lien: Encodable { let url: String }

    private func enregistrer() async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        do {
            let rendu: CalendrierEtCollecte
            if let existant {
                rendu = try await foyer.demander("PUT", "appli/calendriers/\(existant.id)/lien",
                                                 corps: ClientAPI.corps(Lien(url: propre)))
            } else {
                let nom = libelle.trimmingCharacters(in: .whitespaces)
                rendu = try await foyer.demander("POST", "appli/calendriers", corps: ClientAPI.corps(
                    Nouveau(url: propre, nature: nature.rawValue, pour: pour, libelle: nom.isEmpty ? nil : nom)))
            }
            annoncer("« \(rendu.calendrier.libelle) » suivi · " + (rendu.collecte?.enClair ?? "lecture en cours"))
            await apres?()
            await foyer.charger()
            fermer()
        } catch {
            erreur = motifDe(error)
        }
    }
}

// MARK: - 5.12 Calendriers abonnés

/// Ce que l'app Calendrier du téléphone affiche : son planning complet, ou un
/// calendrier composé de certaines personnes et certains contenus (NOT-5 à NOT-9).
struct EcranCalendriersAbonnes: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @Environment(\.openURL) private var ouvrir
    @State private var complet: LienAbonnement?
    @State private var composes: [CalendrierCompose]?
    @State private var erreur: String?
    @State private var renouveler = false
    @State private var composition = false
    @State private var aSupprimer: CalendrierCompose?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                if !foyer.connecte {
                    Text("Connecte-toi à ton serveur pour t'abonner à ton planning.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    if let complet {
                        carte(titre: "Tout mon planning", sousTitre: foyer.moi.nom,
                              contenus: FamilleCalendrier.allCases.map(\.rawValue), url: complet.url, compose: nil)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                    ForEach(composes ?? []) { compose in
                        carte(titre: compose.libelle, sousTitre: (compose.noms ?? []).joined(separator: " et "),
                              contenus: compose.contenus, url: compose.url, compose: compose)
                    }
                    Button("Nouveau calendrier") { composition = true }
                        .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
                    Button { renouveler = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Renouveler mon lien personnel").texte(.corps)
                                    .foregroundStyle(Categorie.alerte.couleur)
                                Text("coupe les anciens abonnements, rien d'autre").texte(.legende)
                                    .foregroundStyle(Palette.texteSecondaire)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Palette.texteTertiaire)
                        }
                        .padding(Espace.interne)
                        .carte(rayon: Rayon.controle)
                    }
                    .buttonStyle(.plain)
                    LigneErreur(texte: erreur)
                }
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Calendriers")
        .navigationBarTitleDisplayMode(.inline)
        .vuParHAL("Réglages, calendriers abonnés")
        .task { await charger() }
        .confirmationDialog("Renouveler le lien ?", isPresented: $renouveler, titleVisibility: .visible) {
            Button("Renouveler", role: .destructive) { Task { await renouvelerLeLien() } }
        } message: {
            Text("Il faudra recoller le nouveau lien partout.")
        }
        .confirmationDialog("Supprimer « \(aSupprimer?.libelle ?? "") » ?",
                            isPresented: Binding { aSupprimer != nil } set: { if !$0 { aSupprimer = nil } },
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let compose = aSupprimer { Task { await supprimer(compose) } }
            }
        }
        .sheet(isPresented: $composition) {
            NavigationStack { FormulaireComposition { await charger() } }.feuilleEnVerre()
        }
    }

    /// 5.12 : un calendrier, ses familles allumées, et de quoi s'y abonner.
    private func carte(titre: String, sousTitre: String, contenus: [String], url: String?,
                       compose: CalendrierCompose?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Pastille(icone: "calendar", couleur: Categorie.travail.couleur)
                VStack(alignment: .leading, spacing: 1) {
                    Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Text(sousTitre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                Spacer()
                if let compose {
                    Menu {
                        Button("Supprimer", systemImage: "trash", role: .destructive) { aSupprimer = compose }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(Palette.texteSecondaire)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Options de \(titre)")
                }
            }
            Flux(espacement: 6) {
                ForEach(FamilleCalendrier.allCases) { famille in
                    let dedans = contenus.contains(famille.rawValue)
                    Text(famille.libelle).texte(.legende)
                        .foregroundStyle(dedans ? Palette.textePrincipal : Palette.texteTertiaire)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(dedans ? famille.categorie.voile : Palette.verreTeinte, in: Capsule())
                }
            }
            .accessibilityElement(children: .combine)
            if let url {
                HStack(spacing: 10) {
                    Button("Copier le lien") {
                        UIPasteboard.general.string = url
                        annoncer("Lien copié")
                    }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                    Button("Ajouter à Calendrier") {
                        if let lien = URL(string: url.replacingOccurrences(
                            of: #"^https?://"#, with: "webcal://", options: .regularExpression)) {
                            ouvrir(lien)
                        }
                    }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                }
            }
        }
        .padding(Espace.interne)
        .carte()
    }

    private func resume(_ compose: CalendrierCompose) -> String {
        let familles = FamilleCalendrier.allCases.filter { compose.contenus.contains($0.rawValue) }
            .map { $0.libelle.lowercased() }.joined(separator: ", ")
        return "\((compose.noms ?? []).joined(separator: " et ")) · \(familles)"
    }

    private func charger() async {
        guard foyer.connecte else { return }
        do {
            complet = try await foyer.demander("GET", "moi/calendrier")
            composes = try await foyer.demander("GET", "moi/calendriers")
            erreur = nil
        } catch {
            erreur = motifDe(error)
        }
    }

    private func renouvelerLeLien() async {
        do {
            complet = try await foyer.demander("POST", "moi/calendrier/renouveler")
            annoncer("Nouveau lien : recolle-le dans tes calendriers")
        } catch {
            erreur = motifDe(error)
        }
    }

    private func supprimer(_ compose: CalendrierCompose) async {
        do {
            try await foyer.agir("DELETE", "moi/calendriers/\(compose.id)")
            composes?.removeAll { $0.id == compose.id }
            annoncer("« \(compose.libelle) » supprimé")
        } catch {
            erreur = motifDe(error)
        }
    }
}

/// Composer un calendrier : des personnes, des familles de contenu (NOT-5, NOT-6, NOT-9).
private struct FormulaireComposition: View {
    let apres: () async -> Void
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var personnes: Set<Int> = []
    @State private var familles: Set<FamilleCalendrier> = []
    @State private var libelle = ""
    @State private var envoi = false
    @State private var erreur: String?

    var body: some View {
        FormulaireVerre {
            Section("Qui") {
                ForEach(foyer.membres) { membre in
                    Toggle(membre.id == foyer.moi.id ? "\(membre.nom) (toi)" : membre.nom, isOn: Binding {
                        personnes.contains(membre.id)
                    } set: { oui in
                        if oui { personnes.insert(membre.id) } else { personnes.remove(membre.id) }
                    })
                }
            }
            Section {
                ForEach(FamilleCalendrier.allCases) { famille in
                    Toggle(isOn: Binding {
                        familles.contains(famille)
                    } set: { oui in
                        if oui { familles.insert(famille) } else { familles.remove(famille) }
                    }) {
                        Label { Text(famille.libelle) } icon: {
                            Circle().fill(famille.categorie.couleur).frame(width: 10, height: 10)
                        }
                    }
                }
            } header: {
                Text("Quoi")
            }
            Section("Nom") {
                TextField(nomPropose, text: $libelle)
            }
            LigneRefus(texte: erreur)
            Section {
                Button {
                    Task { await creer() }
                } label: {
                    HStack { Spacer(); if envoi { ProgressView() } else { Text("Créer le lien").bold() }; Spacer() }
                }
                .disabled(personnes.isEmpty || familles.isEmpty || envoi)
            }
        }
        .navigationTitle("Composer un calendrier")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fermer", systemImage: "xmark") { fermer() }
            }
        }
        .onAppear { if personnes.isEmpty { personnes = [foyer.moi.id] } }
    }

    /// « Lorette : cours, sport ».
    private var nomPropose: String {
        let qui = foyer.membres.filter { personnes.contains($0.id) }.map(\.nom).joined(separator: " et ")
        let quoi = FamilleCalendrier.allCases.filter { familles.contains($0) }
            .map { $0.libelle.lowercased() }.joined(separator: ", ")
        return qui.isEmpty || quoi.isEmpty ? "Nom du calendrier" : String("\(qui) : \(quoi)".prefix(60))
    }

    private func creer() async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        let nom = libelle.trimmingCharacters(in: .whitespaces)
        var chemin = URLComponents()
        chemin.path = "moi/calendriers"
        chemin.queryItems = [
            URLQueryItem(name: "libelle", value: nom.isEmpty ? nomPropose : nom),
            URLQueryItem(name: "personnes", value: foyer.membres.filter { personnes.contains($0.id) }
                .map { $0.id == foyer.moi.id || $0.pseudo.isEmpty ? "moi" : $0.pseudo }.joined(separator: ",")),
            URLQueryItem(name: "contenus", value: FamilleCalendrier.allCases.filter { familles.contains($0) }
                .map(\.rawValue).joined(separator: ",")),
        ]
        guard let requete = chemin.percentEncodedQuery else { return }
        let texte = "moi/calendriers?" + requete.replacingOccurrences(of: "+", with: "%2B")
        do {
            let cree: CalendrierCompose = try await foyer.demander("POST", texte)
            if let url = cree.url { UIPasteboard.general.string = url }
            annoncer("« \(cree.libelle) » créé · lien copié")
            await apres()
            fermer()
        } catch {
            erreur = motifDe(error)
        }
    }
}

// MARK: - 5.17 Historique

/// JRN-9 : les actions du foyer jour par jour, avec ce qu'elles ont changé, et
/// une recherche qui ne garde que celles qui parlent d'un mot. Remplace « /pourquoi ».
struct EcranHistorique: View {
    @Environment(Foyer.self) private var foyer
    @State private var actions: [ActionJournal] = []
    @State private var recherche = ""
    @State private var charge = false
    @State private var fin = false
    @State private var suiteEnCours = false
    @State private var erreur: String?

    private static let parPage = 25

    /// Les millisecondes comptent : deux actions tiennent souvent dans la même seconde.
    private static let instant: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    var body: some View {
        FormulaireVerre {
            if !foyer.connecte {
                SansServeur(texte: "L'Historique se lit sur le serveur : connecte-toi pour le voir.")
            } else if !charge {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if actions.isEmpty {
                Section {
                    Text(recherche.isEmpty
                         ? "Le journal est vide pour l'instant. Il se remplit à chaque changement, et garde 90 jours."
                         : "Rien sur 90 jours pour « \(recherche) ». Essaie un autre mot : une tâche, un prénom, un lieu.")
                        .foregroundStyle(Palette.texteSecondaire)
                }
            } else {
                ForEach(parJour) { groupe in
                    Section(titre(groupe.jour)) {
                        ForEach(groupe.actions) { action in
                            LigneAction(action: action, recherche: !recherche.isEmpty)
                        }
                    }
                }
                if !fin {
                    Section {
                        Button {
                            Task { await suite() }
                        } label: {
                            HStack { Text("Plus ancien"); Spacer(); if suiteEnCours { ProgressView() } }
                        }
                        .onAppear { Task { await suite() } }
                    }
                }
            }
            LigneRefus(texte: erreur)
        }
        .navigationTitle("Historique")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $recherche, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Une tâche, un prénom, un lieu")
        .vuParHAL("Réglages, Historique")
        .refreshable { await charger() }
        // Une recherche part quand on s'arrête de taper.
        .task(id: recherche) {
            if !recherche.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await charger()
        }
    }

    private struct Journee: Identifiable {
        let jour: Date
        let actions: [ActionJournal]
        var id: Date { jour }
    }

    private var parJour: [Journee] {
        let calendrier = Calendar.current
        let groupes = Dictionary(grouping: actions) { calendrier.startOfDay(for: $0.quand) }
        return groupes.keys.sorted(by: >).map { Journee(jour: $0, actions: groupes[$0] ?? []) }
    }

    private func titre(_ jour: Date) -> String {
        let calendrier = Calendar.current
        if calendrier.isDateInToday(jour) { return "Aujourd'hui" }
        if calendrier.isDateInYesterday(jour) { return "Hier" }
        return jour.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(enFrancais)).capitalized
    }

    private func chemin(avant: Date?) -> String {
        var morceaux = URLComponents()
        morceaux.path = "journal"
        var parametres = [URLQueryItem(name: "actions", value: "\(Self.parPage)")]
        let mot = recherche.trimmingCharacters(in: .whitespaces)
        if !mot.isEmpty { parametres.append(URLQueryItem(name: "mot", value: mot)) }
        if let avant { parametres.append(URLQueryItem(name: "avant", value: Self.instant.string(from: avant))) }
        morceaux.queryItems = parametres
        return "journal?" + (morceaux.percentEncodedQuery ?? "")
            // « + » dans une heure ISO serait lu comme une espace.
            .replacingOccurrences(of: "+", with: "%2B")
    }

    private func charger() async {
        guard foyer.connecte else { return }
        do {
            let lues: [ActionJournal] = try await foyer.demander("GET", chemin(avant: nil))
            actions = lues
            fin = lues.count < Self.parPage
            erreur = nil
        } catch {
            // Une recherche remplacée par la suivante n'est pas une erreur.
            if Task.isCancelled { return }
            erreur = motifDe(error)
        }
        charge = true
    }

    private func suite() async {
        guard !suiteEnCours, !fin, let derniere = actions.last else { return }
        suiteEnCours = true
        defer { suiteEnCours = false }
        do {
            let lues: [ActionJournal] = try await foyer.demander("GET", chemin(avant: derniere.quand))
            let connues = Set(actions.map(\.id))
            actions += lues.filter { !connues.contains($0.id) }
            fin = lues.count < Self.parPage
        } catch {
            erreur = motifDe(error)
        }
    }
}

/// Une action : quand, qui, et ce qu'elle a changé. Une recherche met en avant
/// ce qui parle du mot, et montre à côté le reste de la même action (JRN-9).
private struct LigneAction: View {
    let action: ActionJournal
    let recherche: Bool
    @State private var deplie = false

    private static let limite = 5

    var body: some View {
        let principales: [ActionJournal.Ligne] = recherche
            ? action.evenements.filter { $0.correspond == true } : action.evenements
        let aCote: [ActionJournal.Ligne] = recherche ? action.evenements.filter { $0.correspond != true } : []
        let montrees = deplie ? principales : Array(principales.prefix(Self.limite))
        let aCoteMontrees = deplie ? aCote : Array(aCote.prefix(3))
        let caches = principales.count - montrees.count + aCote.count - aCoteMontrees.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(action.quand.formatted(date: .omitted, time: .shortened)).bold()
                Text("·")
                Text(action.qui)
                if let origine = origineEnClair {
                    Text("· \(origine)").lineLimit(1)
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.texteSecondaire)

            ForEach(montrees.indices, id: \.self) { rang in
                Text(montrees[rang].phrase)
                    .foregroundStyle(Palette.textePrincipal)
                    .fontWeight(recherche ? .semibold : .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !aCote.isEmpty {
                Text("Dans la même action").font(.caption).foregroundStyle(Palette.texteTertiaire).padding(.top, 2)
                ForEach(aCoteMontrees.indices, id: \.self) { rang in
                    Text(aCoteMontrees[rang].phrase).font(.footnote).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if caches > 0 {
                Button(caches == 1 ? "Voir l'autre" : "Voir les \(caches) autres") {
                    withAnimation(.snappy) { deplie = true }
                }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    /// L'origine quand elle dit quelque chose : une commande du bot, un passage
    /// de l'ordonnanceur. Ce qui vient de l'appli se reconnaît à son auteur.
    private var origineEnClair: String? {
        guard let texte = action.action, !texte.isEmpty, !texte.hasPrefix("application") else { return nil }
        return texte
    }
}
