import SwiftUI

// Les formulaires du « + » (APP-9) : tout se fait à la main, sans HAL. Ce sont
// des Form d'iOS, sans fond à nous : la feuille reste en Liquid Glass.

/// Ce qu'un formulaire montre quand le serveur refuse : son motif, tel quel.
struct LigneErreur: View {
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
    /// La barre d'onglets flotte au-dessus : le bas du formulaire doit pouvoir passer au-dessus d'elle.
    @Environment(\.margeBasse) private var margeBasse

    var body: some View {
        Form {
            Group { contenu }
                .listRowBackground(FondDeLigne())
        }
        .contentMargins(.bottom, margeBasse, for: .scrollContent)
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
struct BoutonEnvoi: View {
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

// L'ajout d'une tâche (TAC-20 à TAC-24) est dans Taches.swift, avec ses types et ses liens.

// MARK: - C'est fait                                                     (EXE-15)

/// 4.4 : ce qui est fait, aujourd'hui, hier ou un autre jour, même pour
/// l'autre (EXE-14, EXE-16). On coche une ou plusieurs tâches prévues ; une
/// tâche qui n'était pas prévue se déclare à part (EXE-17).
struct FormulaireFaite: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer
    @State private var recherche = ""
    @State private var jour = Jour.aujourdhui
    @State private var autreJour = Calendar.current.date(byAdding: .day, value: -2, to: .now) ?? .now
    @State private var choisies: Set<Int> = []
    @State private var enCours = false
    @State private var erreur: String?

    private enum Jour: Hashable { case aujourdhui, hier, autre }

    /// Une tâche prévue qu'on peut déclarer faite.
    private struct Prevue: Identifiable {
        let id: Int
        let titre: String
        let debut: Date?
        let pour: Membre?
        let journee: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.texteSecondaire)
                    TextField("Qu'est-ce que tu as fait ?", text: $recherche)
                        .texte(.corps).foregroundStyle(Palette.textePrincipal)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .verreControle(Capsule(), interactif: false)
                Segmente(choix: [(Jour.aujourdhui, "Aujourd'hui"), (Jour.hier, "Hier"), (Jour.autre, "Autre jour")],
                         selection: $jour)
                if jour == .autre {
                    HStack {
                        Text("Le").texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        DatePicker("Jour", selection: $autreJour, in: ...Date.now, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .padding(.horizontal, Espace.interne)
                    .padding(.vertical, 8)
                    .carte(rayon: Rayon.controle)
                }
                let liste = prevues
                if liste.isEmpty {
                    Text(recherche.isEmpty ? "Rien de prévu dans les jours qui viennent." : "Aucune tâche prévue ne correspond.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(liste.enumerated()), id: \.element.id) { rang, tache in
                            ligne(tache)
                            if rang < liste.count - 1 { Divider().overlay(Palette.verreBord) }
                        }
                    }
                    .carte(rayon: Rayon.controle)
                }
                NavigationLink { FaiteEnPlus(quand: quand) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Categorie.sport.couleur)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Une tâche en plus, pas prévue").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                            Text("une tâche du foyer faite en avance, ou en dehors du planning")
                                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Espace.interne)
                    .background {
                        RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous)
                            .strokeBorder(Palette.verreBord, style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let erreur {
                    Label(erreur, systemImage: "exclamationmark.circle")
                        .texte(.corps).foregroundStyle(Categorie.alerte.couleur)
                }
                Button { Task { await valider() } } label: {
                    HStack {
                        if enCours { ProgressView() }
                        Text(choisies.isEmpty ? "Valider" : "Valider (\(choisies.count))")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                .disabled(choisies.isEmpty || enCours)
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .margeDeLaBarre()
        .scrollDismissesKeyboard(.interactively)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("C'est fait")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Les tâches du jour pas encore faites, puis celles des prochains jours.
    private var prevues: [Prevue] {
        let aujourdhui = foyer.tachesDuJour.filter { !$0.faite }.map {
            Prevue(id: $0.id, titre: $0.titre, debut: $0.debut, pour: $0.pourQui, journee: $0.journeeEntiere)
        }
        let ensuite = foyer.bientot.map {
            Prevue(id: $0.id, titre: $0.libelle, debut: $0.debut, pour: foyer.membre(numero: $0.idUtilisateur),
                   journee: $0.journeeEntiere == true)
        }
        var vus = Set<Int>()
        let toutes = (aujourdhui + ensuite).filter { vus.insert($0.id).inserted }
        guard !recherche.isEmpty else { return toutes }
        let cle = recherche.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return toutes.filter {
            $0.titre.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(cle)
        }
    }

    private func ligne(_ tache: Prevue) -> some View {
        let choisie = choisies.contains(tache.id)
        let autre = tache.pour.map { $0 != foyer.moi } ?? false
        return Button {
            withAnimation(.snappy) {
                if choisie { choisies.remove(tache.id) } else { choisies.insert(tache.id) }
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(choisie ? Categorie.sport.couleur : Palette.texteSecondaire, lineWidth: 1.5)
                    if choisie {
                        Circle().fill(Categorie.sport.couleur)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black.opacity(0.8))
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tache.titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                    Text(sousTitre(tache, autre: autre)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if autre, let pour = tache.pour {
                    Avatar(nom: pour.nom, couleur: foyer.couleur(de: pour), taille: 26)
                }
            }
            .padding(.horizontal, Espace.interne)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choisie ? .isSelected : [])
    }

    /// « prévue ce soir pour toi », « prévue mer. pour Lorette · elle sera prévenue ».
    private func sousTitre(_ tache: Prevue, autre: Bool) -> String {
        var quand = "prévue"
        if let debut = tache.debut, debut < Calendar.current.startOfDay(for: .now) {
            quand = "en retard depuis " + EnFrancais.jourCourt(debut).lowercased()
        } else if let debut = tache.debut {
            if Calendar.current.isDateInToday(debut) {
                quand += tache.journee ? " aujourd'hui" : (Calendar.current.component(.hour, from: debut) >= 18
                    ? " ce soir" : " à \(EnFrancais.heure(debut))")
            } else {
                quand += " " + EnFrancais.jourCourt(debut).lowercased()
                if !tache.journee { quand += " \(EnFrancais.heure(debut))" }
            }
        }
        if autre, let pour = tache.pour { return "\(quand) pour \(pour.nom) · \(pour.nom) le saura" }
        return "\(quand) pour toi"
    }

    /// L'heure déclarée : maintenant, hier soir, ou le jour choisi en soirée.
    private var quand: Date {
        let calendrier = Calendar.current
        switch jour {
        case .aujourdhui: return .now
        case .hier:
            let hier = calendrier.date(byAdding: .day, value: -1, to: .now) ?? .now
            return calendrier.date(bySettingHour: 20, minute: 0, second: 0, of: hier) ?? hier
        case .autre:
            return calendrier.date(bySettingHour: 20, minute: 0, second: 0, of: autreJour) ?? autreJour
        }
    }

    private struct Validation: Encodable { let dateReelle: Date }

    private func valider() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        let date = min(quand, .now)
        var faites = 0
        for id in choisies {
            do {
                try await foyer.agir("POST", "occurrences/\(id)/valider",
                                     corps: ClientAPI.corps(Validation(dateReelle: date)))
                faites += 1
            } catch {
                erreur = motif(error)
            }
        }
        if faites > 0 {
            await foyer.charger()
            annoncer(faites == 1 ? "Tâche faite" : "\(faites) tâches faites")
        }
        if erreur == nil { (fermerFeuille?.fermer ?? { fermer() })() }
    }
}

/// EXE-17 : une tâche du foyer faite sans être prévue. La suivante repart de là.
private struct FaiteEnPlus: View {
    let quand: Date
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer
    @State private var taches: [TacheRecurrente] = []
    @State private var enCours: Int?
    @State private var erreur: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                Text("Celle que tu touches compte faite \(EnFrancais.jour(quand)).")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
                if let erreur {
                    Label(erreur, systemImage: "exclamationmark.circle")
                        .texte(.corps).foregroundStyle(Categorie.alerte.couleur)
                }
                if taches.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(taches.enumerated()), id: \.element.id) { rang, tache in
                            Button { Task { await declarer(tache) } } label: {
                                HStack {
                                    Text(tache.libelle).texte(.corps).foregroundStyle(Palette.textePrincipal)
                                    Spacer()
                                    if enCours == tache.id { ProgressView() }
                                }
                                .padding(.horizontal, Espace.interne)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(enCours != nil)
                            if rang < taches.count - 1 { Divider().overlay(Palette.verreBord) }
                        }
                    }
                    .carte(rayon: Rayon.controle)
                }
            }
            .padding(Espace.marge)
        }
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Une tâche en plus")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let toutes: [TacheRecurrente] = try await foyer.demander("GET", "taches")
                taches = toutes.filter { $0.categorie != "sport" }
            } catch {
                erreur = motif(error)
            }
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
                                 corps: ClientAPI.corps(Demande(codeTache: tache.code, quand: min(quand, .now))))
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
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                HStack(spacing: 12) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Categorie.ia.couleur, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("En faire moins quelques jours").texte(.titreWidget)
                            .foregroundStyle(Palette.textePrincipal)
                        Text(etat?.enCours == true ? etat?.texte ?? "" : "Examens, fatigue, grosse semaine de travail.")
                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Espace.interne)
                .carte()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(etat?.enCours == true ? "Encore" : "Pendant").texte(.corps)
                            .foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        Compteur(titre: "Jours", valeur: duree, bornes: 1...14,
                                 unite: jours == 1 ? "jour" : "jours", compact: true)
                            .frame(width: 150)
                            .padding(.vertical, 6)
                            .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    Text(jusquau).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                .padding(Espace.interne)
                .carte()

                partage

                LigneErreur(texte: erreur)
                Button { Task { await activer() } } label: {
                    HStack {
                        if enCours { ProgressView() }
                        Text(etat?.enCours == true ? "Changer pour \(libelleJours)" : "Activer pour \(libelleJours)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                .disabled(etat == nil || enCours)
                if etat?.enCours == true {
                    Button("Arrêter le mode allégé") { Task { await arreter() } }
                        .buttonStyle(.hal(.verre, pleineLargeur: true))
                }
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .margeDeLaBarre()
        .scrollBounceBehavior(.basedOnSize)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Mode allégé")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { etat = try await foyer.demander("GET", "allegement") } catch { erreur = motif(error) }
        }
    }

    private var duree: Binding<Double> {
        Binding(get: { Double(jours) }, set: { jours = Int($0) })
    }

    private var libelleJours: String { jours == 1 ? "aujourd'hui" : "\(jours) jours" }

    /// Le dernier jour compris : aujourd'hui plus la durée, moins un.
    private var jusquau: String {
        guard jours > 1,
              let dernier = Calendar.current.date(byAdding: .day, value: jours - 1, to: .now) else {
            return "Aujourd'hui seulement"
        }
        return "Jusqu'au \(dernier.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))) inclus"
    }

    /// PLA-16 : un quart pour moi, trois quarts pour l'autre.
    private var partage: some View {
        let autres = foyer.membres.filter { $0.id != foyer.moi.id }
        let nomAutre = autres.count == 1 ? autres[0].nom : "Les autres"
        return VStack(alignment: .leading, spacing: 10) {
            Text("TÂCHES PARTAGÉES PENDANT CE TEMPS").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(foyer.couleur(de: foyer.moi)).frame(width: geo.size.width * 0.25)
                    Capsule().fill(autres.first.map { foyer.couleur(de: $0) } ?? Palette.texteTertiaire)
                }
            }
            .frame(height: 8)
            HStack {
                Text("Toi · 25 %").texte(.corpsFort)
                Spacer()
                Text("\(nomAutre) · 75 %").texte(.corpsFort)
            }
            .foregroundStyle(Palette.textePrincipal)
        }
        .padding(Espace.interne)
        .carte()
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
