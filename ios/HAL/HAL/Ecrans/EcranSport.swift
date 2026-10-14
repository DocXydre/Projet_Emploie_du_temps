import SwiftUI

/// L'onglet Sport, dans l'ordre fixe de la maquette [3.1] (WID-4) : la forme du
/// jour, le plan, la semaine, la charge, l'évolution, les progrès, les séances
/// de la montre, la mesure demandée. Ce qui attend une réponse passe devant :
/// la séance en cours ou celle du jour, une invitation, la semaine à valider.
struct EcranSport: View {
    @Environment(Foyer.self) private var foyer
    @Environment(SeanceEnCours.self) private var seance
    @Environment(EnvoiSante.self) private var sante
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.annoncer) private var annoncer
    @State private var prevue: DetailSeance?
    @State private var annonce = false
    @State private var periode = 30

    var body: some View {
        PageDefilante {
            EnTeteOnglet(surTitre: surTitre, titre: "Sport") {
                BoutonRond("plus", libelle: "Annoncer une séance libre") { annonce = true }
            }
            .padding(.bottom, 4)
            BandeauServeur()
            etats
            Segmente(choix: [(7, "Semaine"), (30, "Mois"), (90, "3 mois")], selection: $periode)
            FormeDuJour(periode: periode)
            NavigationLink { EcranObjectifs() } label: { CartePlan() }.buttonStyle(.plain)
            CetteSemaine()
            CarteCharge()
            CarteEvolution(periode: periode)
            NavigationLink { EcranProgression() } label: { CarteProgres() }.buttonStyle(.plain)
            NavigationLink { EcranSeancesMontre() } label: { CarteMontre() }.buttonStyle(.plain)
            if foyer.mesureDemandee != nil { WidgetFixe(module: .mesureDemandee) }
            if let bilan = sante.dernierBilan {
                Text("Santé : \(bilan)").texte(.legende).foregroundStyle(Palette.texteTertiaire)
            }
        }
        .refreshable {
            await foyer.charger()
            await sante.envoyer(raison: "à la demande")
            foyer.poserLaFrequence(sante.frequenceDuJour)
        }
        .onChange(of: periode) { _, jours in Task { await foyer.changerLaPeriodeDeSante(jours) } }
        .sheet(item: $prevue) { detail in EcranSeancePrevue(detail: detail) }
        .sheet(isPresented: $annonce) {
            NavigationStack { FormulaireAnnonce() }.feuilleEnVerre()
        }
    }

    /// « Semaine 2 sur 4 · charge », ou « En pause ».
    private var surTitre: String {
        if enPause { return "En pause" }
        guard let semaines = foyer.complements.plan?.plan?.semaines,
              let rang = semaines.firstIndex(where: { Calendar.current.isDate($0.lundi, equalTo: .now, toGranularity: .weekOfYear) })
        else { return "Cette semaine" }
        let role = TexteHAL.role(semaines[rang].role)
        return "Semaine \(rang + 1) sur \(semaines.count)" + (role.isEmpty ? "" : " · \(role)")
    }

    private var enPause: Bool {
        foyer.connecte ? foyer.sportDuServeur?.pause != nil : foyer.essais.pause
    }

    /// Les états qui attendent une réponse, en tête.
    @ViewBuilder private var etats: some View {
        if foyer.connecte && sante.disponible && !sante.accesDemande {
            // 8.7 : sans Santé, la forme, le sommeil et les séances de la montre restent vides.
            CarteVide(icone: "heart", categorie: .alerte, titre: "Santé n'est pas encore lue",
                      texte: "Ton sommeil, ta fréquence cardiaque et les séances de ta montre remplissent cet onglet, et aident HAL à doser tes séances.",
                      bouton: "Autoriser Santé") {
                Task { await sante.demanderAcces() }
            }
        }
        if enPause {
            // PAU-1 : la pause se lève d'ici, ou depuis Réglages.
            BandeauEtat(icone: "pause", titre: "HAL est en pause",
                        detail: "Les séances se posent à la main ; le récap passe un soir sur trois",
                        categorie: .ia, bouton: foyer.connecte ? "Reprendre" : nil) {
                Task {
                    do {
                        try await foyer.agir("DELETE", "coach/pause")
                        annoncer("Pause levée : HAL prépare la reprise")
                    } catch {
                        annoncer((error as? ErreurAPI)?.message ?? "Impossible pour l'instant")
                    }
                }
            }
        }
        if let bloc = foyer.sportDuServeur?.demarrage {
            // DEM-1, 7.18 : le démarrage, ou sa reprise là où on s'était arrêté.
            Button { conversation.demarrageOuvert = true } label: {
                BandeauEtat(icone: "sparkle",
                            titre: bloc == "profil" ? "Démarrer HAL" : "Reprendre le démarrage",
                            detail: bloc == "profil"
                                ? "Quelques questions, et HAL te propose quatre semaines"
                                : "Il reste : \(EcranDemarrage.nomDuBloc(bloc))",
                            categorie: .ia)
            }
            .buttonStyle(.plain)
        }
        if seance.enCours {
            WidgetFixe(module: .seanceEnCours)
        } else if let detail = foyer.seanceDuJour {
            WidgetFixe(module: .lancerSeance)
                .onTapGesture { prevue = detail }
        }
        if let semaine = foyer.sportDuServeur?.semaineAValider {
            NavigationLink { EcranSemaine() } label: {
                BandeauEtat(icone: "calendar.badge.checkmark", titre: "Semaine à valider",
                            detail: "\(semaine.seances) séance\(semaine.seances > 1 ? "s" : "") proposée\(semaine.seances > 1 ? "s" : "") par HAL",
                            categorie: .ia)
            }
            .buttonStyle(.plain)
        }
        ForEach(foyer.sportDuServeur?.invitations ?? []) { invitation in
            BandeauInvitation(invitation: invitation)
        }
        ForEach(foyer.sportDuServeur?.seancesDuJour.filter { !$0.close && $0.seance.discipline != "musculation" } ?? []) { course in
            Button { prevue = course } label: {
                BandeauEtat(icone: "figure.run", titre: "\(course.titre) aujourd'hui",
                            detail: course.prevu.first?.consigne ?? course.seance.consigne ?? "Le détail de la séance",
                            categorie: .sport)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Forme du jour

/// Sommeil, VFC, FC de repos et pas du dernier jour reçu, comparés à la
/// moyenne de la période choisie. Un jour sans donnée s'écrit par un tiret (APP-4).
private struct FormeDuJour: View {
    let periode: Int
    @Environment(Foyer.self) private var foyer

    var body: some View {
        let jours = foyer.complements.sante?.jours ?? []
        let dernier = jours.last ?? foyer.sportDuServeur?.forme.first
        VStack(alignment: .leading, spacing: Espace.gouttiere) {
            HStack(alignment: .firstTextBaseline) {
                Text("Forme du jour").texte(.titre).foregroundStyle(Palette.textePrincipal).surLaPhoto()
                Spacer()
                if let dernier {
                    Text("Santé · \(EnFrancais.jour(dernier.jour))")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire).surLaPhoto()
                }
            }
            Grid(horizontalSpacing: Espace.gouttiere, verticalSpacing: Espace.gouttiere) {
                GridRow {
                    lien(EcranSommeil()) {
                        Mesure(titre: "Sommeil", icone: "bed.double",
                               valeur: dernier?.sommeilMinutes.map { EnFrancais.duree(minutes: $0) },
                               tendance: ecart(dernier?.sommeilMinutes.map(Double.init), jours.compactMap { $0.sommeilMinutes.map(Double.init) }) {
                                   "\($0 >= 0 ? "+" : "−")\(EnFrancais.duree(minutes: Int(abs($0).rounded()))) vs moyenne"
                               },
                               couleur: Categorie.linge.couleur)
                    }
                    lien(EcranSommeil()) {
                        Mesure(titre: "VFC", icone: "waveform.path.ecg",
                               valeur: dernier?.vfcMs.map { String(Int($0.rounded())) }, unite: "ms",
                               tendance: ecart(dernier?.vfcMs, jours.compactMap(\.vfcMs)) {
                                   "\($0 >= 0 ? "+" : "−")\(Int(abs($0).rounded())) vs \(periode) j"
                               },
                               couleur: Categorie.ia.couleur)
                    }
                }
                GridRow {
                    lien(EcranFrequence()) {
                        Mesure(titre: "FC repos", icone: "heart",
                               valeur: dernier?.fcRepos.map(String.init), unite: "bpm",
                               tendance: ecart(dernier?.fcRepos.map(Double.init), jours.compactMap { $0.fcRepos.map(Double.init) }) {
                                   "\($0 >= 0 ? "+" : "−")\(Int(abs($0).rounded())) vs \(periode) j"
                               })
                    }
                    lien(EcranSommeil()) {
                        Mesure(titre: "Pas", icone: "figure.walk",
                               valeur: dernier?.pas.map(EnFrancais.nombre),
                               tendance: moyenne(jours.compactMap { $0.pas.map(Double.init) }).map {
                                   "moyenne \(EnFrancais.nombre(Int($0.rounded())))"
                               },
                               couleur: Categorie.sport.couleur)
                    }
                }
            }
        }
    }

    private func moyenne(_ valeurs: [Double]) -> Double? {
        valeurs.isEmpty ? nil : valeurs.reduce(0, +) / Double(valeurs.count)
    }

    /// L'écart du dernier jour à la moyenne de la période, mis en mots.
    private func ecart(_ valeur: Double?, _ valeurs: [Double], _ texte: (Double) -> String) -> String? {
        guard let valeur, valeurs.count > 2, let moyenne = moyenne(valeurs) else { return nil }
        return texte(valeur - moyenne)
    }

    private func lien<Destination: View, Contenu: View>(_ destination: Destination,
                                                        @ViewBuilder contenu: () -> Contenu) -> some View {
        NavigationLink { destination } label: { contenu() }.buttonStyle(.plain)
    }
}

// MARK: - Plan

/// Le plan sur quatre semaines : l'objectif principal, l'avis de HAL, les
/// semaines et leur rôle (OBJ, PLN-1). Toucher ouvre les objectifs [3.18].
private struct CartePlan: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.theme) private var theme

    var body: some View {
        let lu = foyer.complements.plan
        CoquilleWidget(titre: "Plan · \(lu?.plan?.semaines.count ?? 4) semaines", icone: "calendar",
                       couleur: Categorie.travail.couleur,
                       droite: lu?.plan?.au.map { "jusqu'au \($0.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))" }) {
            if let plan = lu?.plan {
                VStack(alignment: .leading, spacing: 12) {
                    if let objectif = lu?.objectifPrincipal {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "trophy")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Categorie.sport.couleur)
                                .frame(width: 40, height: 40)
                                .background(Categorie.sport.voile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(objectif.libelle).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                                Text(sousTitre(objectif)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(plan.semaines.enumerated()), id: \.offset) { rang, semaine in
                            tuile(rang, semaine)
                        }
                    }
                }
            } else {
                VideWidget(texte: "Pas encore de plan. HAL le construit au démarrage.")
                    .frame(minHeight: 80)
            }
        }
    }

    private func sousTitre(_ objectif: ObjectifDetaille) -> String {
        var morceaux = ["Objectif principal"]
        if let echeance = objectif.echeance {
            morceaux.append(echeance.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "fr_FR"))))
        }
        if let avis = TexteHAL.avis(objectif.avis) { morceaux.append("avis : \(avis)") }
        return morceaux.joined(separator: " · ")
    }

    private func tuile(_ rang: Int, _ semaine: PlanHAL.Plan.Semaine) -> some View {
        let courante = Calendar.current.isDate(semaine.lundi, equalTo: .now, toGranularity: .weekOfYear)
        let passee = semaine.lundi < .now && !courante
        let etat: String
        if courante {
            etat = "\(foyer.semaine.faites)/\(foyer.semaine.prevues)"
        } else if passee {
            etat = "✓"
        } else {
            etat = semaine.validee == nil ? "esquisse" : "validée"
        }
        return VStack(spacing: 2) {
            Text("S\(rang + 1)").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            Text(TexteHAL.role(semaine.role).capitalized).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(etat).texte(.legende)
                .foregroundStyle(passee ? Categorie.sport.couleur : Palette.texteTertiaire)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(courante ? theme.principal : Palette.verreBord, lineWidth: courante ? 1.5 : 0.5))
    }
}

// MARK: - Cette semaine

/// Les séances de la semaine, faites ou à venir, et l'ajustement que HAL
/// propose (PLN-18). Toucher une séance ouvre la semaine [3.2].
private struct CetteSemaine: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        let seances = (foyer.complements.semaine?.seances ?? [])
            .filter { !["retiree", "remplacee"].contains($0.situation ?? "") }
            .sorted { ($0.debut ?? $0.jour) < ($1.debut ?? $1.jour) }
        CoquilleWidget(titre: "Cette semaine", icone: "waveform.path.ecg", couleur: Categorie.sport.couleur,
                       droite: "\(foyer.semaine.faites) sur \(foyer.semaine.prevues)") {
            VStack(alignment: .leading, spacing: 0) {
                if seances.isEmpty {
                    Text("Rien de prévu cette semaine.").texte(.corps).foregroundStyle(Palette.texteSecondaire)
                }
                ForEach(Array(seances.enumerated()), id: \.element.id) { rang, seance in
                    NavigationLink { EcranSemaine() } label: { ligne(seance) }
                        .buttonStyle(.plain)
                    if rang < seances.count - 1 { Divider().overlay(Palette.verreBord) }
                }
                if let ajustement = foyer.ajustement {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Orbe(etat: .repos, taille: 22)
                            Text("\(ajustement.titre). \(ajustement.motif)")
                                .texte(.corps).foregroundStyle(Palette.textePrincipal)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button("Accepter") { repondre(true) }.buttonStyle(.hal(.accent, pleineLargeur: true))
                            Button("Refuser") { repondre(false) }.buttonStyle(.hal(.verre, pleineLargeur: true))
                        }
                    }
                    .padding(12)
                    .background(Categorie.ia.voile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 10)
                }
            }
        }
    }

    private func ligne(_ seance: SemaineDeSport.SeanceDeLaSemaine) -> some View {
        let faite = seance.situation == "faite"
        return HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(EnFrancais.jourCourt(seance.jour)).texte(.legende)
                Text(seance.jour.formatted(.dateTime.day())).texte(.corpsFort)
            }
            .foregroundStyle(faite ? Color.black.opacity(0.8) : Palette.textePrincipal)
            .frame(width: 44, height: 44)
            .background(faite ? Categorie.sport.couleur.opacity(0.85) : Palette.verreTeinte,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(titre(seance)).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                Text(detail(seance)).texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
            }
            Spacer(minLength: 0)
            if faite {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Categorie.sport.couleur)
                    .font(.system(size: 20))
            } else {
                Image(systemName: "chevron.right").foregroundStyle(Palette.texteTertiaire)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func titre(_ seance: SemaineDeSport.SeanceDeLaSemaine) -> String {
        let type = seance.typeSeance ?? ""
        let discipline = Discipline.nom(seance.discipline)
        return type.isEmpty || type == "libre" ? "\(discipline)\(type == "libre" ? " libre" : "")" : type
    }

    /// Faite : ce que la montre a mesuré ce jour-là. À venir : l'heure, le lieu, l'état.
    private func detail(_ seance: SemaineDeSport.SeanceDeLaSemaine) -> String {
        if seance.situation == "faite" {
            var morceaux = ["Faite"]
            if let montre = foyer.seancesDeLaMontre.first(where: {
                $0.discipline == seance.discipline && Calendar.current.isDate($0.debut, inSameDayAs: seance.jour)
            }) {
                if let metres = montre.distanceM, metres > 0 { morceaux.append(EnFrancais.distance(metres)) }
                if let secondes = montre.dureeSecondes { morceaux.append(EnFrancais.chrono(secondes)) }
            } else if let minutes = seance.dureeMinutes {
                morceaux.append(EnFrancais.duree(minutes: minutes))
            }
            return morceaux.joined(separator: " · ")
        }
        var morceaux: [String] = []
        if let debut = seance.debut { morceaux.append(EnFrancais.heure(debut)) }
        if let lieu = seance.lieu { morceaux.append(lieu) }
        switch seance.situation {
        case "validee": morceaux.append("validée")
        case "proposee": morceaux.append("proposée")
        case "pas_faite": morceaux.append("pas faite")
        case let autre?: morceaux.append(autre)
        case nil: break
        }
        return morceaux.joined(separator: " · ")
    }

    private func repondre(_ accepte: Bool) {
        Task {
            do {
                try await foyer.repondreAjustement(accepte: accepte)
                annoncer(accepte ? "Ajustement accepté" : "Ajustement refusé")
            } catch {
                annoncer((error as? ErreurAPI)?.message ?? "Réponse impossible")
            }
        }
    }
}

// MARK: - Charge

/// La charge d'entraînement des sept derniers jours (effort noté × durée,
/// chapitre 8.1), et les minutes de séance jour par jour de cette semaine.
private struct CarteCharge: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        let semaine = foyer.complements.semaine
        let charge = semaine?.charge
        CoquilleWidget(titre: "Charge d'entraînement", icone: "flame", couleur: Categorie.alerte.couleur,
                       droite: "effort × durée") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(charge?.chargeSeptJours.map { EnFrancais.nombre(Int($0.rounded())) } ?? "—")
                        .texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                    Text("sur 7 jours").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    Spacer()
                    if let rapport = charge?.rapport {
                        let pourcent = Int(((rapport - 1) * 100).rounded())
                        Puce(texte: "\(pourcent >= 0 ? "+" : "")\(pourcent) %",
                             couleur: pourcent > 30 ? Categorie.alerte.couleur : Categorie.sport.couleur,
                             fond: pourcent > 30 ? Categorie.alerte.voile : Categorie.sport.voile)
                    }
                }
                Barres(valeurs: minutesParJour(semaine), couleur: Categorie.sport.couleur, hauteur: 80)
                Text(legende(charge)).texte(.legende).foregroundStyle(Palette.texteTertiaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Les minutes des séances faites, du lundi au dimanche.
    private func minutesParJour(_ semaine: SemaineDeSport?) -> [(String, Double)] {
        let calendrier = Calendar.current
        let lundi = semaine?.lundi ?? calendrier.startOfDay(for: .now)
        return (0..<7).map { rang in
            let jour = calendrier.date(byAdding: .day, value: rang, to: lundi) ?? lundi
            let minutes = (semaine?.seances ?? [])
                .filter { $0.situation == "faite" && calendrier.isDate($0.jour, inSameDayAs: jour) }
                .compactMap(\.dureeMinutes).reduce(0, +)
            // Des étiquettes distinctes : le graphique range par étiquette, et
            // mardi et mercredi commencent par la même lettre.
            return (["L", "Ma", "Me", "J", "V", "S", "D"][rang], Double(minutes))
        }
    }

    private func legende(_ charge: SemaineDeSport.Charge?) -> String {
        var texte = "Barres : minutes de séance par jour, cette semaine."
        if let sans = charge?.seancesSansBilan, sans > 0 {
            texte += " \(sans) séance\(sans > 1 ? "s" : "") sans bilan ne compte\(sans > 1 ? "nt" : "") pas."
        }
        return texte
    }
}

// MARK: - Évolution

/// Le poids, la FC de repos, la VFC et l'allure sur la période choisie.
private struct CarteEvolution: View {
    let periode: Int
    @Environment(Foyer.self) private var foyer
    @State private var serie = Serie.poids

    private enum Serie: String, CaseIterable, Identifiable {
        case poids = "Poids", fc = "FC repos", vfc = "VFC", allure = "Allure"
        var id: String { rawValue }
    }

    var body: some View {
        let points = points(serie)
        let valeurs = points.compactMap(\.valeur)
        CoquilleWidget(titre: "Évolution", icone: "chart.line.uptrend.xyaxis", couleur: Categorie.ia.couleur,
                       droite: "\(periode) jours") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(Serie.allCases) { choix in
                        PuceChoix(texte: choix.rawValue, choisie: choix == serie) {
                            withAnimation(.snappy) { serie = choix }
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(valeurs.last.map(enClair) ?? "—").texte(.chiffre).foregroundStyle(Palette.textePrincipal)
                    Text(unite).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    Spacer()
                    if let premier = valeurs.first, let dernier = valeurs.last, valeurs.count > 1 {
                        Text("\(dernier - premier >= 0 ? "+" : "−")\(enClair(abs(dernier - premier))) \(unite) en \(periode) j")
                            .texte(.legende).foregroundStyle(Categorie.sport.couleur)
                    }
                }
                if valeurs.count > 1 {
                    Courbe(points: points, couleur: Categorie.ia.couleur, hauteur: 90)
                } else {
                    Text("Pas assez de données sur la période.")
                        .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                if serie == .poids {
                    NavigationLink { EcranMesures() } label: {
                        HStack(spacing: 4) {
                            Text("Toutes les mesures")
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        }
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var unite: String {
        switch serie {
        case .poids: "kg"
        case .fc: "bpm"
        case .vfc: "ms"
        case .allure: "/km"
        }
    }

    private func enClair(_ valeur: Double) -> String {
        switch serie {
        case .allure: EnFrancais.chrono(Int(valeur.rounded()))
        case .poids: valeur.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "fr_FR")))
        default: String(Int(valeur.rounded()))
        }
    }

    private func points(_ serie: Serie) -> [PointSerie] {
        let depuis = Calendar.current.date(byAdding: .day, value: -periode, to: .now) ?? .now
        let jours = foyer.complements.sante?.jours ?? []
        switch serie {
        case .poids:
            return foyer.complements.mesures
                .filter { $0.typeMesure == "poids" && $0.dateMesure >= depuis }
                .sorted { $0.dateMesure < $1.dateMesure }
                .map { PointSerie(date: $0.dateMesure, valeur: $0.valeur) }
        case .fc:
            return jours.map { PointSerie(date: $0.jour, valeur: $0.fcRepos.map(Double.init)) }
        case .vfc:
            return jours.map { PointSerie(date: $0.jour, valeur: $0.vfcMs) }
        case .allure:
            return foyer.seancesDeLaMontre
                .filter { $0.discipline == "course" && $0.debut >= depuis }
                .sorted { $0.debut < $1.debut }
                .map { PointSerie(date: $0.debut, valeur: $0.allureSKm.map(Double.init)) }
        }
    }
}

// MARK: - Progrès

/// Les exercices qui progressent : la meilleure série de la dernière semaine,
/// et l'écart avec quatre semaines plus tôt (EXO-2). Toucher ouvre la progression [3.17].
private struct CarteProgres: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        let lignes = exercices
        CoquilleWidget(titre: "Progrès", icone: "trophy", couleur: Categorie.menage.couleur) {
            if lignes.isEmpty {
                Text("Les progrès apparaissent après quelques séances.")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lignes.enumerated()), id: \.offset) { rang, ligne in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ligne.nom).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                                if let ecart = ligne.ecart {
                                    Text(ecart).texte(.legende).foregroundStyle(Categorie.sport.couleur)
                                }
                            }
                            Spacer()
                            Text(ligne.valeur).texte(.corps).foregroundStyle(Palette.textePrincipal)
                            Image(systemName: "chevron.right").foregroundStyle(Palette.texteTertiaire)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.vertical, 8)
                        if rang < lignes.count - 1 { Divider().overlay(Palette.verreBord) }
                    }
                }
            }
        }
    }

    private struct Ligne {
        let nom: String
        let valeur: String
        let ecart: String?
    }

    /// Les trois exercices suivis le plus de semaines.
    private var exercices: [Ligne] {
        let parCode = Dictionary(grouping: foyer.complements.progression, by: \.code)
        let quatreSemaines = Calendar.current.date(byAdding: .day, value: -28, to: .now) ?? .now
        return parCode.values
            .sorted { $0.count > $1.count }
            .prefix(3)
            .compactMap { semaines -> Ligne? in
                let triees = semaines.sorted { $0.lundi < $1.lundi }
                guard let derniere = triees.last else { return nil }
                let nom = Self.nomCourt(derniere.libelle)
                let valeur: String
                if let charge = derniere.meilleureCharge, charge > 0 {
                    valeur = "\(Poids.texte(charge)) × \(derniere.meilleuresRepetitions ?? 0)"
                } else {
                    valeur = "\(derniere.meilleuresRepetitions ?? 0) reps"
                }
                let depart = triees.first { $0.lundi >= quatreSemaines } ?? triees.first
                var ecart: String?
                if let depart, depart.lundi != derniere.lundi {
                    let semaines = max(1, Calendar.current.dateComponents([.weekOfYear], from: depart.lundi, to: derniere.lundi).weekOfYear ?? 1)
                    if let avant = depart.meilleureCharge, let apres = derniere.meilleureCharge, apres != avant {
                        ecart = "\(apres > avant ? "+" : "−")\(Poids.texte(abs(apres - avant))) en \(semaines) sem."
                    } else if let avant = depart.meilleuresRepetitions, let apres = derniere.meilleuresRepetitions, apres != avant {
                        ecart = "\(apres > avant ? "+" : "−")\(abs(apres - avant)) reps en \(semaines) sem."
                    }
                }
                return Ligne(nom: nom, valeur: valeur, ecart: ecart)
            }
    }

    /// « Développé couché » plutôt que « Développé couché à la barre, prise moyenne ».
    private static func nomCourt(_ libelle: String) -> String {
        String(libelle.split(separator: ",").first ?? Substring(libelle))
    }
}

// MARK: - Montre

/// Les deux dernières séances de la montre (MON-2). Toucher ouvre leur détail [3.14].
private struct CarteMontre: View {
    @Environment(Foyer.self) private var foyer

    var body: some View {
        let seances = Array(foyer.seancesDeLaMontre.prefix(2))
        CoquilleWidget(titre: "Dernières séances de la montre", icone: "applewatch",
                       couleur: Categorie.alerte.couleur) {
            if seances.isEmpty {
                Text("Les séances de la montre arrivent par Santé.")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(seances.enumerated()), id: \.offset) { rang, seance in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Discipline.nom(seance.discipline)).texte(.corpsFort)
                                    .foregroundStyle(Palette.textePrincipal)
                                Text("\(EnFrancais.jour(seance.debut)) · \(EnFrancais.heure(seance.debut))")
                                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(principal(seance)).texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                Text(detail(seance)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            }
                        }
                        .padding(.vertical, 8)
                        if rang < seances.count - 1 { Divider().overlay(Palette.verreBord) }
                    }
                }
            }
        }
    }

    private func principal(_ seance: HistoriqueSante.Activite) -> String {
        if let metres = seance.distanceM, metres > 0 { return EnFrancais.distance(metres) }
        return seance.dureeSecondes.map { EnFrancais.duree(minutes: $0 / 60) } ?? "—"
    }

    private func detail(_ seance: HistoriqueSante.Activite) -> String {
        var morceaux: [String] = []
        if let metres = seance.distanceM, metres > 0, let secondes = seance.dureeSecondes {
            morceaux.append(EnFrancais.chrono(secondes))
        }
        if let allure = seance.allureSKm, (seance.distanceM ?? 0) > 0 { morceaux.append("\(EnFrancais.chrono(allure)) /km") }
        if let fc = seance.fcMoyenne { morceaux.append("FC \(fc)") }
        if morceaux.isEmpty, let kcal = seance.energieKcal { morceaux.append("\(kcal) kcal") }
        return morceaux.joined(separator: " · ")
    }
}
