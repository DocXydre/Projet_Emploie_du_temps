import Charts
import SwiftUI

// La séance de musculation, de bout en bout (3.3 à 3.10). Tout marche sans
// réseau : la séance est chargée d'avance, les saisies attendent dans la file.

// MARK: - 3.3 Séance prévue

/// La séance prévue par HAL : ses exercices, « Lancer », « Déjà faite ».
struct EcranSeancePrevue: View {
    let detail: DetailSeance
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @Environment(ConversationHAL.self) private var conversation
    @Environment(Foyer.self) private var foyer
    @State private var pasFaite = false
    @State private var supprimer = false
    @State private var envoyee = false
    @State private var envoi = false
    @State private var versLaMontre = false

    /// 3.3 : sur la photo, comme un écran poussé. Le titre, le lieu, la durée ;
    /// chaque exercice avec son bouton pour le changer (SAI-3) ; puis « Lancer »,
    /// « Demander un changement à HAL », « Déjà faite, sans saisie ».
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                barre
                carteTitre
                if detail.prevu.isEmpty {
                    Text("HAL n'a pas encore détaillé cette séance : tu choisis tes exercices.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        .padding(Espace.interne)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .carte(rayon: Rayon.controle)
                } else if detail.seance.discipline == "musculation" {
                    exercices
                } else if detail.montre?.first == nil {
                    // 3.12 : une course prévue se lit en étapes.
                    EtapesDeCourse(lignes: detail.prevu)
                }
                if let consigne = detail.seance.consigne, !consigne.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Orbe(etat: .repos, taille: 22)
                        Text(consigne).texte(.corps).foregroundStyle(Palette.textePrincipal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Espace.interne)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: Rayon.controle)
                }
                if let montre = detail.montre?.first {
                    // 3.14 : ce que la montre a enregistré, comme l'app Forme.
                    CourseFaite(montre: montre, discipline: detail.seance.discipline)
                    if let avis = detail.seance.avisLibre {
                        HStack(alignment: .top, spacing: 10) {
                            Orbe(etat: .repos, taille: 22)
                            Text(avis).texte(.corps).foregroundStyle(Palette.textePrincipal)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Espace.interne)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .carte(rayon: Rayon.controle)
                    }
                    Text("Données de l'Apple Watch, reçues par Santé. La séance prévue a été validée toute seule.")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire).surLaPhoto()
                }
                actions
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background { Fond() }
        .vuParHAL("\(detail.titre), \(sousTitre)")
        .confirmationDialog("Supprimer cette séance libre ?", isPresented: $supprimer,
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                let id = detail.seance.idOccurrence
                Task {
                    do {
                        try await foyer.agir("DELETE", "seances/\(id)/libre")
                        // SAI-19 : si le téléphone la tenait encore ouverte, il l'oublie.
                        if seance.seance?.idOccurrence == id { seance.oublier() }
                        annoncer("Séance libre supprimée")
                        fermer()
                    } catch {
                        annoncer((error as? ErreurAPI)?.message ?? "Suppression impossible")
                    }
                }
            }
        }
        .confirmationDialog("Cette séance n'a pas été faite ?", isPresented: $pasFaite,
                            titleVisibility: .visible) {
            Button("Pas faite", role: .destructive) {
                file.ajouter(methode: "POST", chemin: "seances/\(detail.seance.idOccurrence)/pas-faite")
                annoncer("Séance notée pas faite : HAL décide de la suite")
                fermer()
            }
        } message: {
            Text("HAL en tient compte pour la suite de la semaine.")
        }
        .task {
            guard ["course", "cardio"].contains(detail.seance.discipline ?? ""), !detail.close else { return }
            envoyee = await EnvoiMontre.dejaEnvoyee(detail.seance.idOccurrence)
        }
        .sheet(isPresented: $versLaMontre) {
            FeuilleMontre(detail: detail, envoi: envoi) {
                versLaMontre = false
                Task { await envoyerALaMontre() }
            }
            .presentationDetents([.large])
            .feuilleEnVerre()
        }
    }

    /// Retour, « Jeu. 15 oct. · 18:30 », et le menu « … ».
    private var barre: some View {
        ZStack {
            Text(dateEnTete).texte(.titreWidget).foregroundStyle(Palette.textePrincipal).surLaPhoto()
            HStack {
                BoutonRond("chevron.left", libelle: "Fermer") { fermer() }
                Spacer()
                if !detail.close {
                    Menu {
                        Button("Pas faite", systemImage: "xmark.circle") { pasFaite = true }
                        if detail.seance.libre == true {
                            Button("Supprimer cette séance libre", systemImage: "trash", role: .destructive) {
                                supprimer = true
                            }
                        }
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
        }
        .frame(height: 44)
        .padding(.top, Espace.serre)
    }

    private var carteTitre: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(detail.titre).texte(.titre).foregroundStyle(Palette.textePrincipal)
                if detail.seance.cle == true { Puce("Clé", categorie: .sport) }
                Spacer(minLength: 4)
                if detail.close, detail.seance.situation == "faite" {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Categorie.sport.couleur)
                } else if ["course", "cardio"].contains(detail.seance.discipline ?? "") {
                    Puce(texte: "Sur la montre")
                } else {
                    Puce(texte: EcranSemaine.situation(detail.seance.situation).capitalized)
                }
            }
            Text(sousTitre).texte(.corps).foregroundStyle(Palette.texteSecondaire)
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: Rayon.controle)
    }

    private var exercices: some View {
        VStack(spacing: 0) {
            ForEach(Array(detail.prevu.enumerated()), id: \.element.id) { rang, ligne in
                HStack(spacing: 12) {
                    Text("\(rang + 1)").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .frame(width: 24, height: 24)
                        .background(Palette.verreTeinte, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ligne.libelle).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Text(ligne.enClair).texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if !detail.close, detail.seance.discipline == "musculation",
                       let alternatives = ligne.alternatives, !alternatives.isEmpty {
                        // SAI-3 : changer d'exercice ne demande pas HAL. Le choix lance
                        // la séance avec l'exercice remplacé.
                        Menu {
                            Section("Lancer avec") {
                                ForEach(alternatives, id: \.idExercice) { alternative in
                                    Button(alternative.libelle) { lancer(remplacant: alternative, rang: rang) }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.textePrincipal)
                                .frame(width: 36, height: 36)
                                .verreControle(Circle())
                        }
                        .accessibilityLabel("Changer \(ligne.libelle)")
                    }
                }
                .padding(.horizontal, Espace.interne)
                .padding(.vertical, 10)
                if rang < detail.prevu.count - 1 { Divider().overlay(Palette.verreBord) }
            }
        }
        .carte(rayon: Rayon.controle)
    }

    @ViewBuilder private var actions: some View {
        if detail.close {
            Label("Séance \(EcranSemaine.situation(detail.seance.situation))", systemImage: "checkmark.circle")
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
        } else {
            if detail.seance.discipline == "musculation" {
                Button(seance.enCours && seance.seance?.idOccurrence == detail.seance.idOccurrence
                       ? "Reprendre la séance" : "Lancer la séance") {
                    seance.lancer(detail)
                    fermer()
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
            } else {
                // MON-1, MON-2 : une course ne se lance pas ici, elle part sur la montre.
                // 3.13 : on voit d'abord ce qui part.
                Button {
                    versLaMontre = true
                } label: {
                    HStack {
                        if envoi { ProgressView() }
                        Text(envoyee ? "Renvoyer à la montre" : "Envoyer à la montre")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                .disabled(envoi)
                if envoyee {
                    Text("Elle t'attend dans l'app Exercice, à son heure. Faite, elle arrive par Santé et se valide toute seule.")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
            Button("Demander un changement à HAL") {
                fermer()
                conversation.demanderUnChangement(ElementJoint(
                    genre: .seance, idOccurrence: detail.seance.idOccurrence,
                    libelle: "\(detail.titre) · \(sousTitre)"))
            }
            .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
            Button("Déjà faite, sans saisie") {
                SeanceEnCours.dejaFaite(detail, file: file)
                annoncer("Séance comptée faite")
                fermer()
            }
            .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
        }
    }

    /// Lance la séance, l'exercice choisi remplaçant le prévu, puis revient au premier.
    private func lancer(remplacant: LignePrevue.Alternative, rang: Int) {
        seance.lancer(detail)
        seance.aller(a: rang)
        seance.remplacer(par: remplacant)
        seance.aller(a: 0)
        annoncer("\(remplacant.libelle) à la place")
        fermer()
    }

    /// « Jeu. 15 oct. · 18:30 »
    private var dateEnTete: String {
        guard let debut = detail.seance.debut ?? detail.seance.jour else { return "Séance" }
        let jour = EnFrancais.jour(debut)
        let texte = jour.prefix(1).uppercased() + jour.dropFirst()
        return detail.seance.debut.map { "\(texte) · \(EnFrancais.heure($0))" } ?? texte
    }

    private func envoyerALaMontre() async {
        envoi = true
        defer { envoi = false }
        do {
            try await EnvoiMontre.envoyer(detail)
            envoyee = true
            annoncer("Séance envoyée à la montre")
        } catch {
            annoncer(error.localizedDescription)
        }
    }

    /// « Salle de musculation · 55 min · modérée »
    private var sousTitre: String {
        var morceaux: [String] = []
        if let lieu = detail.seance.lieu { morceaux.append(lieu) }
        if let duree = detail.seance.dureeMinutes { morceaux.append(EnFrancais.duree(minutes: duree)) }
        if let intensite = detail.seance.intensite { morceaux.append(VueSeanceDuJour.intensite(intensite).lowercased()) }
        return morceaux.joined(separator: " · ")
    }
}

/// 3.13 : ce qui part sur l'Apple Watch, avant de l'envoyer : les étapes, et
/// l'alerte qui sonnera (MON-1). Elle attend dans l'app Exercice, à son heure.
private struct FeuilleMontre: View {
    let detail: DetailSeance
    let envoi: Bool
    var envoyer: () -> Void
    @Environment(\.dismiss) private var fermer

    var body: some View {
        let alerte = EnvoiMontre.alerteEnClair(detail)
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                HStack {
                    Text("Envoyer à la montre").texte(.titre).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    BoutonRond("xmark", libelle: "Fermer") { fermer() }
                }
                HStack(spacing: 12) {
                    Image(systemName: "applewatch")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Categorie.sport.couleur)
                        .frame(width: 40, height: 40)
                        .background(Categorie.sport.voile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Apple Watch").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                        Text("par l'app Exercice").texte(.legende).foregroundStyle(Categorie.sport.couleur)
                    }
                    Spacer()
                }
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
                VStack(alignment: .leading, spacing: 10) {
                    Text("CE QUI ARRIVE SUR LA MONTRE").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                    ForEach(detail.prevu) { ligne in
                        HStack(spacing: 10) {
                            Circle().fill(Categorie.sport.couleur).frame(width: 7, height: 7)
                            Text(ligne.libelle).texte(.corps).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ligne.enClair).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                }
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
                VStack(spacing: 0) {
                    ligne(alerte.titre, alerte.detail)
                    Divider().overlay(Palette.verreBord)
                    ligne("Rappel sur la montre",
                          (detail.seance.debut ?? detail.seance.jour).map { "\(EnFrancais.jour($0)) · \(EnFrancais.heure($0))" } ?? "à son heure")
                }
                .padding(.horizontal, Espace.interne)
                .carte(rayon: Rayon.controle)
                Text("Faite, elle revient par Santé et la séance prévue se valide toute seule.")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                Button(action: envoyer) {
                    HStack {
                        if envoi { ProgressView() }
                        Text("Envoyer à la montre")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                .disabled(envoi)
            }
            .padding(Espace.marge)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func ligne(_ titre: String, _ detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(titre).texte(.corps).foregroundStyle(Palette.textePrincipal)
                Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            Spacer()
            Image(systemName: "checkmark").foregroundStyle(Categorie.sport.couleur)
        }
        .padding(.vertical, 10)
    }
}

/// 3.12 : les étapes d'une course prévue, numérotées, avec leur durée ou
/// leur distance et la consigne de HAL. L'étape principale est mise en avant.
private struct EtapesDeCourse: View {
    let lignes: [LignePrevue]

    var body: some View {
        let total = lignes.reduce(0) { $0 + ($1.distanceM ?? 0) * max(1, $1.series ?? 1) }
        CoquilleWidget(titre: "Étapes", icone: "waveform.path.ecg", couleur: Categorie.sport.couleur,
                       droite: total > 0 ? "≈ \(EnFrancais.distance(total))" : nil) {
            VStack(spacing: 0) {
                ForEach(Array(lignes.enumerated()), id: \.element.id) { rang, ligne in
                    let principale = rang == principale
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(rang + 1)").texte(.legende)
                            .foregroundStyle(principale ? Color.black.opacity(0.8) : Palette.texteSecondaire)
                            .frame(width: 24, height: 24)
                            .background(principale ? Categorie.sport.couleur : Palette.verreTeinte, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(titre(ligne)).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                            Text(sousTitre(ligne)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    if rang < lignes.count - 1 { Divider().overlay(Palette.verreBord) }
                }
            }
        }
    }

    /// L'étape la plus longue : le corps de la séance.
    private var principale: Int {
        lignes.indices.max { a, b in
            Self.poids(lignes[a]) < Self.poids(lignes[b])
        } ?? 0
    }

    private static func poids(_ ligne: LignePrevue) -> Int {
        (ligne.dureeSecondes ?? 0) * max(1, ligne.series ?? 1) + (ligne.distanceM ?? 0)
    }

    /// « 6 × 2 min », « 30 min », « 5 km »
    private func titre(_ ligne: LignePrevue) -> String {
        let series = ligne.series ?? 1
        let mesure: String? = ligne.dureeSecondes.map { secondes in
            secondes % 60 == 0 ? EnFrancais.duree(minutes: secondes / 60) : "\(secondes) s"
        } ?? ligne.distanceM.map { $0 >= 1000 ? EnFrancais.distance($0) : "\($0) m" }
        guard let mesure else { return ligne.libelle }
        return series > 1 ? "\(series) × \(mesure)" : mesure
    }

    private func sousTitre(_ ligne: LignePrevue) -> String {
        var morceaux = [ligne.libelle]
        if let consigne = ligne.consigne, !consigne.isEmpty { morceaux.append(consigne) }
        if let repos = ligne.reposSecondes, (ligne.series ?? 1) > 1 { morceaux.append("\(repos) s de récupération") }
        return morceaux.joined(separator: " · ")
    }
}

/// 3.14, MON-4 : une course faite, comme l'app Forme la montre. Les chiffres,
/// puis, quand la montre les a donnés, les kilomètres, la fréquence cardiaque,
/// les zones et l'allure.
private struct CourseFaite: View {
    let montre: DetailSeance.Montre
    let discipline: String?

    var body: some View {
        VStack(spacing: Espace.gouttiere) {
            chiffres
            if let kilometres = montre.details?.kilometres, !kilometres.isEmpty {
                carteKilometres(kilometres)
            }
            if let frequence = montre.details?.frequence, frequence.count > 1 {
                carteFrequence(frequence)
            }
            if let zones = montre.details?.zones, zones.count == 5, zones.reduce(0, +) > 0 {
                carteZones(zones)
            }
            if let kilometres = montre.details?.kilometres, kilometres.count > 1 {
                carteAllure(kilometres)
            }
        }
    }

    private var chiffres: some View {
        let colonnes = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
        return LazyVGrid(columns: colonnes, alignment: .leading, spacing: 14) {
            chiffre("Distance", montre.distanceM.map(EnFrancais.distance), couleur: Categorie.sport.couleur)
            chiffre("Durée", montre.dureeSecondes.map(EnFrancais.chrono))
            chiffre("Allure moyenne", montre.allureSKm.map { "\(EnFrancais.chrono($0)) /km" })
            chiffre("FC moyenne", montre.fcMoyenne.map { "\($0) bpm" }, couleur: Categorie.alerte.couleur)
            chiffre("Dénivelé +", montre.deniveleM.map { "\($0) m" })
            chiffre("Énergie active", montre.energieKcal.map { "\($0) kcal" })
            chiffre("Cadence", montre.cadence.map { "\($0) pas/min" })
            chiffre("FC max", montre.fcMax.map { "\($0) bpm" })
        }
        .padding(Espace.interne)
        .carte(rayon: Rayon.controle)
    }

    /// APP-4 : une donnée absente s'écrit par un tiret.
    private func chiffre(_ titre: String, _ valeur: String?, couleur: Color = Palette.textePrincipal) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(titre).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            Text(valeur ?? "—").texte(.titre).foregroundStyle(valeur == nil ? Palette.texteTertiaire : couleur)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func carteKilometres(_ kilometres: [Int]) -> some View {
        let plusRapide = Double(kilometres.min() ?? 1)
        let plusLent = Double(kilometres.max() ?? 1)
        return CoquilleWidget(titre: "Temps au kilomètre", icone: "clock", couleur: Categorie.travail.couleur) {
            VStack(spacing: 8) {
                ForEach(Array(kilometres.enumerated()), id: \.offset) { rang, secondes in
                    HStack(spacing: 10) {
                        Text("\(rang + 1)").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                            .frame(width: 20, alignment: .leading)
                        GeometryReader { geo in
                            // La barre la plus longue est le kilomètre le plus rapide.
                            let part = plusLent > plusRapide
                                ? 0.55 + 0.45 * (plusLent - Double(secondes)) / (plusLent - plusRapide) : 1
                            Capsule().fill(Categorie.sport.couleur).frame(width: geo.size.width * part, height: 8)
                                .frame(maxHeight: .infinity)
                        }
                        .frame(height: 18)
                        Text(EnFrancais.chrono(secondes)).texte(.corps).foregroundStyle(Palette.textePrincipal)
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func carteFrequence(_ frequence: [Int]) -> some View {
        CoquilleWidget(titre: "Fréquence cardiaque", icone: "heart", couleur: Categorie.alerte.couleur,
                       droite: (montre.fcMax ?? frequence.max()).map { "max \($0)" }) {
            Chart {
                ForEach(Array(frequence.enumerated()), id: \.offset) { minute, bpm in
                    LineMark(x: .value("Minute", minute), y: .value("bpm", bpm))
                        .foregroundStyle(Categorie.alerte.couleur)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { valeur in
                    AxisValueLabel { Text("\(valeur.as(Int.self) ?? 0) min") }.foregroundStyle(Palette.texteTertiaire)
                }
            }
            .frame(height: 110)
        }
    }

    private func carteZones(_ zones: [Int]) -> some View {
        let total = Double(max(1, zones.reduce(0, +)))
        let couleurs = [Categorie.travail.couleur, Categorie.sport.couleur, Categorie.menage.couleur,
                        Categorie.alerte.couleur, Categorie.linge.couleur]
        return CoquilleWidget(titre: "Zones cardiaques", icone: "heart.text.square", couleur: Categorie.alerte.couleur) {
            VStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { rang in
                    HStack(spacing: 10) {
                        Text("Zone \(rang + 1)").texte(.corps).foregroundStyle(Palette.textePrincipal)
                            .frame(width: 60, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.verreTeinte)
                                Capsule().fill(couleurs[rang])
                                    .frame(width: max(6, geo.size.width * Double(zones[rang]) / total))
                            }
                            .frame(height: 8)
                            .frame(maxHeight: .infinity)
                        }
                        .frame(height: 18)
                        Text(EnFrancais.chrono(zones[rang])).texte(.corps).foregroundStyle(Palette.textePrincipal)
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func carteAllure(_ kilometres: [Int]) -> some View {
        CoquilleWidget(titre: "Allure", icone: "waveform.path.ecg", couleur: Categorie.sport.couleur,
                       droite: "plus bas = plus vite") {
            Chart {
                ForEach(Array(kilometres.enumerated()), id: \.offset) { rang, secondes in
                    LineMark(x: .value("Kilomètre", rang + 1), y: .value("Allure", secondes))
                        .foregroundStyle(Categorie.sport.couleur)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic) { valeur in
                    AxisValueLabel { Text("\(valeur.as(Int.self) ?? 0) km") }.foregroundStyle(Palette.texteTertiaire)
                }
            }
            .frame(height: 100)
        }
    }
}

// MARK: - 3.5 Séance en cours

/// Gros boutons, une main, les gants : la séance en cours (SAI-1, SAI-10).
struct EcranSeanceEnCours: View {
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @Environment(Foyer.self) private var foyer
    /// SAI-20 : les records de chaque exercice déjà lus pendant la séance.
    @State private var records: [String: RecordsExercice] = [:]
    @State private var charge: Double = 20
    @State private var reps: Double = 10
    @State private var duree: Double = 30
    @State private var distance: Double = 500
    @State private var bloque = false
    @State private var terminer = false
    @State private var choisir = false
    @State private var bilan = false
    @State private var annuler = false
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Espace.gouttiere) {
                    entete
                    if !file.reseauDisponible && !file.enAttente.isEmpty {
                        Label("Hors réseau · \(file.enAttente.count) envoi\(file.enAttente.count > 1 ? "s" : "") gardé\(file.enAttente.count > 1 ? "s" : "") sur le téléphone",
                              systemImage: "wifi.slash")
                            .texte(.legende).foregroundStyle(Categorie.menage.couleur)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Categorie.menage.voile, in: RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous))
                    }
                    if let exercices = seance.seance?.exercices, !exercices.isEmpty {
                        avancee(exercices)
                    }
                    if let exercice = seance.exerciceCourant {
                        carteExercice(exercice)
                        ensuite
                    } else {
                        aucunExercice
                    }
                }
                .padding(Espace.marge)
            }
            .scrollIndicators(.hidden)
            .overlay {
                // 3.7 : le repos prend tout l'écran ; la séance se devine dessous.
                if let fin = seance.finDuRepos, fin > .now {
                    Repos(fin: fin, duree: seance.dureeDuRepos, suite: suiteApresLeRepos,
                          ajuster: { seance.ajusterLeRepos($0) }, passer: { seance.passerLeRepos() })
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: seance.finDuRepos)
            .background { Fond() }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $bloque) {
                FeuilleBloque(repsVisees: Int(reps)) { faites in
                    seance.bloque(charge: charge, repsFaites: faites, repsVisees: Int(reps), file: file)
                    preRemplir()
                }
                .presentationDetents([.medium])
                .feuilleEnVerre()
            }
            .sheet(isPresented: $choisir) {
                ChoixExercice { exercice in seance.ajouter(exercice); preRemplir() }
                    .feuilleEnVerre()
            }
            .sheet(isPresented: $terminer) {
                FeuilleTerminer(prevue: seance.seance?.idOccurrence != nil) { choix in
                    switch choix {
                    case .bilan: bilan = true
                    case .pasFaite: seance.pasFaite(file: file)
                    case .annuler:
                        // La feuille se referme d'abord : la question vient juste après.
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            annuler = true
                        }
                    }
                }
                .presentationDetents([.fraction(0.78), .large])
                .feuilleEnVerre()
            }
            .navigationDestination(isPresented: $bilan) { EcranBilan() }
            .confirmationDialog("Annuler toute la séance ?", isPresented: $annuler, titleVisibility: .visible) {
                Button("Annuler la séance", role: .destructive) {
                    let prevue = seance.seance?.idOccurrence != nil
                    seance.annuler(file: file)
                    annoncer(prevue ? "Lancement annulé : la séance reste à faire" : "Séance annulée")
                }
                Button("Continuer la séance", role: .cancel) {}
            } message: {
                Text(seance.seance?.idOccurrence != nil
                     ? "Elle reste à faire. Les séries saisies pendant ce lancement sont effacées."
                     : "Rien n'est gardé : la séance et ses séries sont effacées.")
            }
        }
        .onAppear(perform: preRemplir)
        .onChange(of: seance.exerciceCourant?.id) { preRemplir() }
    }

    /// 3.5 : la croix et « Bilan » ouvrent la fin de séance (3.8) ; le titre et le chrono au milieu.
    private var entete: some View {
        ZStack {
            VStack(spacing: 0) {
                Text(seance.seance?.titre ?? "Séance").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                TimelineView(.periodic(from: .now, by: 1)) { contexte in
                    let secondes = Int(contexte.date.timeIntervalSince(seance.seance?.debut ?? .now))
                    Text(EnFrancais.chrono(max(0, secondes))).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .monospacedDigit()
                }
            }
            .surLaPhoto()
            HStack(spacing: 8) {
                BoutonRond("xmark", libelle: "Fin de séance") { terminer = true }
                Spacer()
                BoutonRond("chevron.down", libelle: "Réduire la séance") { seance.affichee = false }
                Button("Bilan") { terminer = true }.buttonStyle(.hal(.verre))
            }
        }
        .frame(height: 44)
    }

    /// « Exercice 1 sur 5 » et un trait par exercice ; toucher un trait y va.
    private func avancee(_ exercices: [ExerciceDeSeance]) -> some View {
        let courant = seance.seance?.courant ?? 0
        return HStack(spacing: 10) {
            Text("Exercice \(courant + 1) sur \(exercices.count)")
                .texte(.legende).foregroundStyle(Palette.texteSecondaire).surLaPhoto()
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(exercices.indices, id: \.self) { rang in
                    let fini = exercices[rang].series.map { seance.series(de: exercices[rang])
                        .filter { !$0.intermediaire }.count >= $0 } ?? false
                    Button { seance.aller(a: rang) } label: {
                        Capsule()
                            .fill(rang == courant ? Categorie.sport.couleur
                                  : fini ? Categorie.sport.couleur.opacity(0.45) : Palette.verreTeinteForte)
                            .frame(width: rang == courant ? 26 : 18, height: 5)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(exercices[rang].libelle)
                }
                Button { choisir = true } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.textePrincipal)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .verreControle(Circle())
                .accessibilityLabel("Ajouter un exercice")
            }
        }
    }

    /// « Ensuite : Tirage horizontal », en bas ; le toucher y va.
    @ViewBuilder private var ensuite: some View {
        if let seanceLocale = seance.seance, seanceLocale.courant + 1 < seanceLocale.exercices.count {
            let suivant = seanceLocale.exercices[seanceLocale.courant + 1]
            Button { seance.aller(a: seanceLocale.courant + 1) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "dumbbell").foregroundStyle(Palette.texteSecondaire)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ensuite : \(suivant.libelle)").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                            .lineLimit(1)
                        if let prevu = prevuEnClair(suivant, avecRepos: false) {
                            Text(prevu).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Palette.texteTertiaire)
                }
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
            }
            .buttonStyle(.plain)
        }
    }

    /// Ce que montre le repos : la série qui vient.
    private var suiteApresLeRepos: String? {
        guard let exercice = seance.exerciceCourant else { return nil }
        let faites = seance.series(de: exercice).filter { !$0.intermediaire }.count
        let proposee = seance.proposee(pour: exercice)
        let numero = seance.seance?.proposition?.intermediaire == true ? "Série intermédiaire" : "Série \(faites + 1)"
        let valeur = SerieLocale.texte(charge: proposee.chargeKg, reps: proposee.repetitions,
                                       duree: proposee.dureeSecondes, distance: proposee.distanceM)
        return "\(numero) · \(valeur)\n\(exercice.libelle)"
    }

    /// 3.5 : l'exercice, ce qui est prévu, puis ses séries : faites, celle en
    /// cours avec sa saisie, celles qui restent. Une série bloquée s'écrit en ambre (3.6).
    private func carteExercice(_ exercice: ExerciceDeSeance) -> some View {
        let faites = seance.series(de: exercice)
        let normales = faites.filter { !$0.intermediaire }.count
        let prevues = exercice.series ?? max(normales + 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(exercice.libelle).texte(.titre).foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !exercice.alternatives.isEmpty {
                    Menu {
                        ForEach(exercice.alternatives, id: \.code) { alternative in
                            Button(alternative.libelle) { seance.remplacer(par: alternative); preRemplir() }
                        }
                    } label: {
                        Label("Changer", systemImage: "arrow.left.arrow.right")
                            .texte(.legende).foregroundStyle(Palette.textePrincipal)
                            .padding(.horizontal, 12).frame(height: 30)
                            .verreControle(Capsule())
                    }
                }
            }
            if let prevu = prevuEnClair(exercice, avecRepos: true) {
                Text(prevu).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            if let consigne = exercice.consigne, !consigne.isEmpty {
                AvisDeHAL(texte: consigne, style: .legende, secondaire: true)
            }
            if !exercice.enDuree && !exercice.enDistance {
                troisPoids(exercice)
            }
            ForEach(faites) { serie in
                ligneFaite(serie)
            }
            blocEnCours(exercice, numero: normales + 1)
            // Après une série intermédiaire vient la série prévue suivante, pas celle d'après.
            let premiereAVenir = normales + (seance.seance?.proposition?.intermediaire == true ? 1 : 2)
            if premiereAVenir <= prevues {
                ForEach(premiereAVenir...prevues, id: \.self) { numero in
                    HStack {
                        Text("Série \(numero)").texte(.corpsFort)
                        Spacer()
                        Text(prevuDUneSerie(exercice)).texte(.corps)
                    }
                    .foregroundStyle(Palette.texteTertiaire)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous))
                }
            }
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte()
    }

    /// SAI-20 : le poids prévu par HAL, le plus lourd jamais soulevé, et le
    /// plus lourd tenu sur dix répétitions. Toucher l'un le met dans le compteur.
    private func troisPoids(_ exercice: ExerciceDeSeance) -> some View {
        let lus = records[exercice.code]
        return HStack(spacing: 8) {
            tuilePoids("Conseil HAL", exercice.chargeKg,
                       detail: exercice.repetitionsVisees.map { "× \($0)" }, couleur: Categorie.ia.couleur)
            tuilePoids("Ton max", lus?.max?.chargeKg,
                       detail: lus?.max.map { "× \($0.repetitions)" }, couleur: Categorie.sport.couleur)
            tuilePoids("Max à 10 reps", lus?.max10?.chargeKg,
                       detail: lus?.max10.map { "× \($0.repetitions)" }, couleur: Categorie.travail.couleur)
        }
        .task(id: exercice.code) { await lireLesRecords(exercice.code) }
    }

    private func tuilePoids(_ titre: String, _ kilos: Double?, detail: String?, couleur: Color) -> some View {
        Button {
            if let kilos { charge = kilos }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(titre.uppercased()).texte(.etiquette).foregroundStyle(couleur)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(kilos.map(Poids.texte) ?? "—").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(detail ?? " ").texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(kilos == nil)
        .accessibilityLabel("\(titre) : \(kilos.map(Poids.texte) ?? "aucun") \(detail ?? "")")
        .accessibilityHint(kilos == nil ? "" : "Met ce poids dans le compteur")
    }

    /// Hors réseau, les records restent ceux déjà lus, ou un tiret (APP-4).
    private func lireLesRecords(_ code: String) async {
        guard foyer.connecte, records[code] == nil else { return }
        if let lus: RecordsExercice = try? await foyer.demander("GET", "exercices/\(code)/records") {
            records[code] = lus
        }
    }

    private func ligneFaite(_ serie: SerieLocale) -> some View {
        HStack(spacing: 8) {
            Text(serie.intermediaire ? "Intermédiaire" : "Série \(serie.numero)").texte(.corpsFort)
                .foregroundStyle(Palette.textePrincipal)
            Spacer()
            if serie.bloquee {
                Text("\(serie.enClair) · bloqué").texte(.corps).foregroundStyle(Categorie.menage.couleur)
            } else {
                Text(serie.enClair).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Categorie.sport.couleur)
            }
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(serie.bloquee ? Categorie.menage.voile : Palette.verreTeinte,
                    in: RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous))
    }

    /// La série à faire : ses compteurs, « Valider », « J'ai bloqué avant ».
    /// Après un blocage, c'est la série intermédiaire, avec « Annuler » (3.6).
    private func blocEnCours(_ exercice: ExerciceDeSeance, numero: Int) -> some View {
        let intermediaire = seance.seance?.proposition?.intermediaire == true
        return VStack(alignment: .leading, spacing: 10) {
            Text(intermediaire ? "Série intermédiaire · ajoutée" : "Série \(numero)")
                .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            if intermediaire {
                HStack(alignment: .top, spacing: 8) {
                    Orbe(etat: .repos, taille: 18)
                    Text("Le poids baisse, les répétitions restent. Puis la suite au poids prévu.")
                        .texte(.legende).foregroundStyle(Palette.textePrincipal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if exercice.enDuree {
                Compteur(titre: "Durée", valeur: $duree, pas: 5, bornes: 5...3600, unite: "s")
            } else if exercice.enDistance {
                Compteur(titre: "Distance", valeur: $distance, pas: 50, bornes: 10...50_000, unite: "m")
            } else {
                Compteur(titre: "Charge", valeur: $charge, pas: 0.5, bornes: 0...500, unite: "kg", saisie: true)
                Compteur(titre: "répétitions", valeur: $reps, pas: 1, bornes: 1...100)
            }
            Button {
                seance.valider(charge: charge, reps: Int(reps), duree: Int(duree), distance: Int(distance), file: file)
                preRemplir()
            } label: {
                Text(intermediaire ? "Valider la série intermédiaire" : "Valider la série \(numero)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
            .sensoryFeedback(.success, trigger: seance.seance?.series.count)
            if intermediaire {
                Button("Annuler") { seance.renoncerALIntermediaire(); preRemplir() }
                    .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
            } else if !exercice.enDuree && !exercice.enDistance {
                Button("J'ai bloqué avant") { bloque = true }
                    .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
            }
        }
        .padding(12)
        .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Categorie.sport.couleur, lineWidth: 1.5))
    }

    /// « 62,5 kg × 6 » : ce que HAL a prévu pour une série.
    private func prevuDUneSerie(_ exercice: ExerciceDeSeance) -> String {
        SerieLocale.texte(charge: exercice.chargeKg, reps: exercice.repetitionsVisees,
                          duree: exercice.dureeSecondes, distance: nil)
    }

    private var aucunExercice: some View {
        VStack(spacing: 12) {
            Image(systemName: "dumbbell").font(.system(size: 30)).foregroundStyle(Categorie.sport.couleur)
            Text("Choisis ton premier exercice").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
            Text("Ceux que tu as faits récemment passent en premier.")
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            Button("Chercher un exercice") { choisir = true }.buttonStyle(.hal(.accent))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .carte()
    }

    private func prevuEnClair(_ exercice: ExerciceDeSeance, avecRepos: Bool) -> String? {
        var morceaux: [String] = []
        if let series = exercice.series, let haut = exercice.repetitionsVisees {
            let bas = exercice.repetitionsMin ?? haut
            morceaux.append(bas == haut ? "\(series) × \(haut)" : "\(series) × \(bas)-\(haut)")
        }
        if let charge = exercice.chargeKg { morceaux.append(Poids.texte(charge)) }
        if avecRepos, let repos = exercice.reposSecondes {
            morceaux.append(repos >= 60 && repos % 60 == 0 ? "repos \(repos / 60) min" : "repos \(repos) s")
        }
        return morceaux.isEmpty ? nil : (avecRepos ? "Prévu : " : "") + morceaux.joined(separator: " · ")
    }

    private func preRemplir() {
        guard let exercice = seance.exerciceCourant else { return }
        let proposee = seance.proposee(pour: exercice)
        if let valeur = proposee.chargeKg { charge = valeur }
        if let valeur = proposee.repetitions { reps = Double(valeur) }
        if let valeur = proposee.dureeSecondes { duree = Double(valeur) }
        if let valeur = proposee.distanceM { distance = Double(valeur) }
    }
}

// MARK: - 3.7 Repos

/// 3.7 : le repos, en grand, par-dessus la séance floutée. Il se compte tout
/// seul ; −15 s, +30 s ou « Passer ». Un retour haptique à la fin.
private struct Repos: View {
    let fin: Date
    let duree: TimeInterval
    let suite: String?
    var ajuster: (TimeInterval) -> Void
    var passer: () -> Void
    @State private var fini = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { contexte in
            let reste = max(0, fin.timeIntervalSince(contexte.date))
            VStack(spacing: 24) {
                Spacer()
                Text("REPOS").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                ZStack {
                    Anneau(valeur: duree > 0 ? reste / duree : 0, couleur: Categorie.sport.couleur, epaisseur: 12)
                    VStack(spacing: 4) {
                        Text(EnFrancais.chrono(Int(reste.rounded(.up))))
                            .font(.system(size: 64, weight: .bold).monospacedDigit())
                            .foregroundStyle(Palette.textePrincipal)
                        Text("sur \(EnFrancais.chrono(Int(duree)))").texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                }
                .frame(width: 230, height: 230)
                HStack(spacing: 10) {
                    Button("−15 s") { ajuster(-15) }.buttonStyle(.hal(.verre, grand: true))
                    Button("+30 s") { ajuster(30) }.buttonStyle(.hal(.verre, grand: true))
                    Button("Passer", action: passer).buttonStyle(.hal(.accent, grand: true))
                }
                if let suite {
                    let lignes = suite.split(separator: "\n").map(String.init)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lignes.first ?? "").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                        if lignes.count > 1 {
                            Text(lignes[1]).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                    }
                    .padding(Espace.interne)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: Rayon.controle)
                }
                Spacer()
                Spacer()
            }
            .padding(.horizontal, Espace.marge)
            .onChange(of: reste == 0) { _, termine in if termine { fini = true } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.35))
        .sensoryFeedback(.success, trigger: fini)
    }
}

// MARK: - 3.6 Série bloquée

/// SAI-17 : à combien de répétitions on s'est arrêté.
private struct FeuilleBloque: View {
    let repsVisees: Int
    var valider: (Int) -> Void
    @Environment(\.dismiss) private var fermer
    @State private var faites: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Espace.gouttiere) {
            Text("J'ai bloqué avant").texte(.titre).foregroundStyle(Palette.textePrincipal)
            Text("La série est notée telle quelle. Une série intermédiaire suit, avec le poids un peu baissé.")
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            Compteur(titre: "Répétitions faites", valeur: $faites, pas: 1, bornes: 0...Double(max(0, repsVisees - 1)))
            Button("Noter la série") {
                valider(Int(faites))
                fermer()
            }
            .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
        }
        .padding(Espace.marge)
        .onAppear { faites = Double(max(0, repsVisees - 2)) }
    }
}

// MARK: - 3.8 Terminer ou arrêter

private enum FinDeSeance { case bilan, pasFaite, annuler }

/// 3.8, SAI-15 : tout est saisi, arrêtée ici, faite sans rien saisir, ou pas
/// faite. On choisit, puis le bouton du bas dit ce qui suit.
private struct FeuilleTerminer: View {
    let prevue: Bool
    var choisir: (FinDeSeance) -> Void
    @Environment(SeanceEnCours.self) private var seance
    @Environment(\.dismiss) private var fermer
    @State private var choix = Choix.toutSaisi

    private enum Choix: CaseIterable {
        case toutSaisi, arreter, sansSaisie, pasFaite, annuler
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fin de la séance").texte(.titre).foregroundStyle(Palette.textePrincipal)
                        Text(resume).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                    Spacer()
                    BoutonRond("xmark", libelle: "Continuer la séance") { fermer() }
                }
                .padding(.bottom, 4)
                ligne(.toutSaisi, "J'ai fini, tout est saisi", "checkmark", Categorie.sport.couleur,
                      "passe au bilan et à la note d'effort")
                ligne(.arreter, "Arrêter ici", "pause.fill", Categorie.menage.couleur,
                      "faite, mais je n'ai pas saisi le reste : seules les séries entrées comptent")
                ligne(.sansSaisie, "Faite, sans rien saisir", "dumbbell", Categorie.sport.couleur,
                      "HAL la compte faite, sans charges ni séries")
                if prevue {
                    ligne(.pasFaite, "Pas faite", "xmark", Categorie.alerte.couleur, "je n'ai pas pu la faire")
                }
                // SAI-19 : lancée par erreur, elle s'annule entière.
                ligne(.annuler, "Annuler le lancement", "arrow.uturn.backward", Palette.texteSecondaire,
                      prevue ? "lancée par erreur : elle reste à faire, sans les séries de ce lancement"
                             : "lancée par erreur : rien n'est gardé")
                Button(libelleBouton) {
                    fermer()
                    switch choix {
                    case .toutSaisi, .arreter, .sansSaisie: choisir(.bilan)
                    case .pasFaite: choisir(.pasFaite)
                    case .annuler: choisir(.annuler)
                    }
                }
                .buttonStyle(.hal(choix == .pasFaite || choix == .annuler ? .danger : .accent,
                                  pleineLargeur: true, grand: true))
                .padding(.top, 4)
            }
            .padding(Espace.marge)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// « 2 exercices sur 5 saisis · 24:12 »
    private var resume: String {
        let exercices = seance.seance?.exercices ?? []
        let saisis = exercices.filter { !seance.series(de: $0).isEmpty }.count
        let secondes = Int(Date.now.timeIntervalSince(seance.seance?.debut ?? .now))
        let chrono = EnFrancais.chrono(max(0, secondes))
        guard !exercices.isEmpty else { return "Rien saisi · \(chrono)" }
        return "\(saisis) exercice\(saisis > 1 ? "s" : "") sur \(exercices.count) saisi\(saisis > 1 ? "s" : "") · \(chrono)"
    }

    private var libelleBouton: String {
        switch choix {
        case .toutSaisi, .arreter, .sansSaisie: "Continuer vers le bilan"
        case .pasFaite: "Noter la séance pas faite"
        case .annuler: "Annuler le lancement"
        }
    }

    private func ligne(_ valeur: Choix, _ titre: String, _ icone: String, _ couleur: Color,
                       _ detail: String) -> some View {
        let choisi = choix == valeur
        return Button { withAnimation(.snappy) { choix = valeur } } label: {
            HStack(spacing: 12) {
                Image(systemName: icone)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(couleur, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if choisi {
                    Image(systemName: "checkmark").foregroundStyle(Categorie.sport.couleur)
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .padding(12)
            .background(choisi ? Categorie.sport.voile : Palette.verreTeinte,
                        in: RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Rayon.controle, style: .continuous)
                .strokeBorder(choisi ? Categorie.sport.couleur : Palette.verreBord, lineWidth: choisi ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 3.9 Bilan

/// SAI-4 : l'effort de 1 à 10, la durée réelle, un commentaire. HAL répond
/// tout de suite si on le demande (SAI-7) ; sa réponse arrive dans son panneau.
struct EcranBilan: View {
    @Environment(SeanceEnCours.self) private var seance
    @Environment(FileAttente.self) private var file
    @Environment(\.annoncer) private var annoncer
    @Environment(\.dismiss) private var fermer
    @State private var effort = 7
    @State private var minutes: Double = 60
    @State private var commentaire = ""
    @State private var avisDeHAL = true

    /// 3.9 : la durée, les séries et le volume ; la note d'effort de 1 à 10 ;
    /// la durée réelle et un commentaire ; puis « Enregistrer le bilan ».
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                ZStack {
                    Text("Bilan · \(seance.seance?.titre ?? "Séance")")
                        .texte(.titreWidget).foregroundStyle(Palette.textePrincipal).surLaPhoto()
                    HStack {
                        BoutonRond("chevron.left", libelle: "Retour à la séance") { fermer() }
                        Spacer()
                        Menu {
                            Toggle("Avoir l'avis de HAL tout de suite", isOn: $avisDeHAL)
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
                chiffres
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 4) {
                        ForEach(1...10, id: \.self) { note in
                            Button { withAnimation(.snappy) { effort = note } } label: {
                                Text("\(note)").texte(.corpsFort)
                                    .foregroundStyle(note == effort ? Color.black.opacity(0.85) : Palette.texteSecondaire)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(note == effort ? Categorie.sport.couleur : Palette.verreTeinte,
                                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Effort \(note) sur 10")
                        }
                    }
                    Text("\(effort) · \(libelleEffort)").texte(.corps).foregroundStyle(Palette.textePrincipal)
                }
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
                VStack(spacing: 10) {
                    HStack {
                        Text("Durée réelle").texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        Compteur(titre: "min", valeur: $minutes, pas: 1, bornes: 5...300, compact: true)
                            .frame(width: 200)
                    }
                    TextField("Une douleur, une machine prise, une forme du jour…", text: $commentaire, axis: .vertical)
                        .texte(.corps).foregroundStyle(Palette.textePrincipal)
                        .lineLimit(2...5)
                        .padding(12)
                        .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Rayon.ligne, style: .continuous)
                            .strokeBorder(Palette.verreBord, lineWidth: 0.5))
                }
                .padding(Espace.interne)
                .carte(rayon: Rayon.controle)
                Button("Enregistrer le bilan") {
                    seance.bilan(effort: effort, minutes: Int(minutes), commentaire: commentaire,
                                 avisDeHAL: avisDeHAL, file: file)
                    annoncer(avisDeHAL ? "Séance close : HAL te répond dans son panneau" : "Séance close")
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                if avisDeHAL {
                    HStack(alignment: .top, spacing: 10) {
                        Orbe(etat: .repos, taille: 22)
                        Text("HAL répond tout de suite après l'enregistrement, dans son panneau.")
                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                    .padding(Espace.interne)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: Rayon.controle)
                }
            }
            .padding(.horizontal, Espace.marge)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .ecranHAL()
        .background { Fond() }
        .onAppear { minutes = Double(max(5, seance.minutesEcoulees)) }
    }

    /// « 58 min · 18 séries · 4 210 kg »
    private var chiffres: some View {
        let series = seance.seance?.series ?? []
        let volume = series.reduce(0.0) { $0 + ($1.chargeKg ?? 0) * Double($1.repetitions ?? 0) }
        return HStack {
            chiffre(EnFrancais.duree(minutes: seance.minutesEcoulees), "durée")
            chiffre("\(series.count)", "séries")
            chiffre(volume > 0 ? "\(EnFrancais.nombre(Int(volume.rounded()))) kg" : "—", "volume")
        }
        .padding(.vertical, 12)
        .carte(rayon: Rayon.controle)
    }

    private func chiffre(_ valeur: String, _ legende: String) -> some View {
        VStack(spacing: 1) {
            Text(valeur).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
            Text(legende).texte(.legende).foregroundStyle(Palette.texteSecondaire)
        }
        .frame(maxWidth: .infinity)
    }

    private var libelleEffort: String {
        switch effort {
        case ...3: "facile, il en restait beaucoup"
        case 4...5: "modéré"
        case 6...7: "dur mais propre"
        case 8...9: "très dur, presque rien en réserve"
        default: "maximal"
        }
    }
}

// MARK: - 3.10 Choisir un exercice

/// LIB-2 : chercher un exercice. Ceux faits récemment d'abord ; ceux qu'une
/// limitation interdit sont grisés (SEC-1). Le catalogue est gardé sur le
/// téléphone pour la salle sans réseau.
struct ChoixExercice: View {
    var choisir: (ExerciceCatalogue) -> Void
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @State private var catalogue: [ExerciceCatalogue] = ChoixExercice.garde()
    @State private var recherche = ""

    /// 3.10 : un champ de recherche, puis les exercices sur le verre. Le
    /// groupe, le matériel et la dernière fois ; un exercice qu'une limitation
    /// interdit est grisé, avec la raison en rouge (SEC-1).
    var body: some View {
        VStack(spacing: Espace.gouttiere) {
            HStack {
                Text("Ajouter un exercice").texte(.titre).foregroundStyle(Palette.textePrincipal)
                Spacer()
                BoutonRond("xmark", libelle: "Fermer") { fermer() }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.texteSecondaire)
                TextField("Développé, squat, rowing…", text: $recherche)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !recherche.isEmpty {
                    Button { recherche = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.texteTertiaire)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .verreControle(Capsule(), interactif: false)
            ScrollView {
                if catalogue.isEmpty {
                    Text("Catalogue indisponible sans réseau. Reconnecte-toi une fois pour le garder.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                        .padding(.top, 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filtres.prefix(60).enumerated()), id: \.element.id) { rang, exercice in
                            ligne(exercice)
                            if rang < min(filtres.count, 60) - 1 { Divider().overlay(Palette.verreBord) }
                        }
                    }
                    .carte(rayon: Rayon.controle)
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(Espace.marge)
        .task { await charger() }
    }

    private func ligne(_ exercice: ExerciceCatalogue) -> some View {
        let interdit = exercice.interdit == true
        return Button {
            choisir(exercice)
            fermer()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(exercice.libelle).texte(.corpsFort)
                        .foregroundStyle(interdit ? Palette.texteTertiaire : Palette.textePrincipal)
                        .lineLimit(1)
                    Text(sousTitre(exercice)).texte(.legende)
                        .foregroundStyle(interdit ? Categorie.alerte.couleur : Palette.texteSecondaire)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !interdit {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textePrincipal)
                        .frame(width: 32, height: 32)
                        .verreControle(Circle(), interactif: false)
                }
            }
            .padding(.horizontal, Espace.interne)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(interdit)
    }

    /// « Dos · poulie · fait il y a 3 jours », ou « Épaules · interdit par une limitation ».
    private func sousTitre(_ exercice: ExerciceCatalogue) -> String {
        var morceaux: [String] = []
        if let groupe = exercice.groupePrincipal { morceaux.append(EnFrancais.groupe(groupe)) }
        if exercice.interdit == true {
            morceaux.append("interdit par une limitation")
        } else {
            if let materiel = exercice.materiel { morceaux.append(EnFrancais.materiel(materiel).lowercased()) }
            morceaux.append(exercice.derniereSaisie.map {
                "fait " + $0.formatted(.relative(presentation: .named))
            } ?? "jamais fait")
        }
        return morceaux.joined(separator: " · ")
    }

    private var filtres: [ExerciceCatalogue] {
        let tries = catalogue.sorted { a, b in
            switch (a.derniereSaisie, b.derniereSaisie) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.libelle < b.libelle
            }
        }
        guard !recherche.isEmpty else { return tries }
        let cle = recherche.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return tries.filter {
            $0.libelle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(cle)
        }
    }

    private func charger() async {
        guard let lus: [ExerciceCatalogue] = try? await foyer.demander("GET", "exercices?discipline=musculation")
        else { return }
        catalogue = lus
        if let donnees = try? ClientAPI.encodeur.encode(lus) {
            try? donnees.write(to: Foyer.fichier("catalogue.json"), options: .atomic)
        }
    }

    private static func garde() -> [ExerciceCatalogue] {
        guard let donnees = try? Data(contentsOf: Foyer.fichier("catalogue.json")) else { return [] }
        return (try? ClientAPI.decodeur.decode([ExerciceCatalogue].self, from: donnees)) ?? []
    }
}
