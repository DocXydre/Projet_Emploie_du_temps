import SwiftUI

// Ce que le lot 6 avait laissé de côté : Santé dans Réglages (5.10), les mesures
// (3.1, 3.19) et les séances de la montre (3.1, 3.14).

private let enFrancais = Locale(identifier: "fr_FR")

private func dateCourte(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(enFrancais))
}

private func raison(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

// MARK: - 5.10 Santé et Apple Watch

/// SAN-10 : l'envoi est automatique. On y voit quand il est passé, et on choisit
/// ce qui est lu. Rien n'est écrit dans Santé.
struct EcranReglagesSante: View {
    @Environment(EnvoiSante.self) private var sante
    @Environment(Foyer.self) private var foyer
    @Environment(\.openURL) private var ouvrir
    @State private var renvoyer = false

    var body: some View {
        FormulaireVerre {
            if !sante.disponible {
                Section {
                    Text("Santé n'est pas disponible sur cet appareil.").foregroundStyle(Palette.textePrincipal)
                }
            }
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Categorie.alerte.couleur, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Envoi automatique").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                        Text(sante.dernierEnvoi.map { "dernier envoi \($0.formatted(.relative(presentation: .named).locale(enFrancais)))" }
                             ?? "jamais envoyé")
                            .texte(.legende)
                            .foregroundStyle(sante.dernierEnvoi == nil ? Palette.texteSecondaire : Categorie.sport.couleur)
                    }
                    Spacer(minLength: 0)
                    if sante.enCours { ProgressView() }
                }
                if let bilan = sante.dernierBilan {
                    Text(bilan).font(.footnote).foregroundStyle(Palette.texteSecondaire)
                }
                Button("Envoyer maintenant") {
                    Task {
                        await sante.envoyer(raison: "à la demande")
                        foyer.poserLaFrequence(sante.frequenceDuJour)
                    }
                }
                .disabled(sante.enCours || !sante.disponible || !foyer.connecte)
            } footer: {
                Text("L'appli lit Santé à chaque ouverture, puis quand iOS la réveille, à peu près toutes les trois heures. Téléphone verrouillé, Santé ne se lit pas : l'envoi attend la prochaine ouverture. Rien à lancer à la main.")
            }

            Section {
                ForEach(EnvoiSante.Donnee.allCases) { donnee in
                    Toggle(isOn: coche(donnee)) {
                        HStack(spacing: 12) {
                            Pastille(icone: donnee.icone, couleur: couleur(donnee))
                            Text(donnee.libelle).foregroundStyle(Palette.textePrincipal)
                        }
                    }
                    .tint(Categorie.sport.couleur)
                }
            } header: {
                Text("Ce qui est lu")
            } footer: {
                Text("Toutes les sources de Santé : la montre, l'iPhone, une balance. Une case décochée n'est plus envoyée ; ce qui est déjà sur le serveur y reste.")
            }

            if sante.lues.contains(.trace) {
                Section {
                    Label {
                        Text("Le tracé montre où tu cours : il reste sur ton serveur, n'est lu que par HAL, et \(foyer.autre?.nom ?? "l'autre membre du foyer") ne le voit pas.")
                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    } icon: {
                        Image(systemName: "lock").foregroundStyle(Categorie.sport.couleur)
                    }
                }
            }

            historique

            Section {
                Button("Autoriser l'accès à Santé") { Task { await sante.demanderAcces() } }
                Button("Ouvrir l'app Santé") {
                    if let lien = URL(string: "x-apple-health://") { ouvrir(lien) }
                }
            } footer: {
                Text("Dans la fenêtre d'iOS, choisis « Toutes les données enregistrées » : sinon HAL ne voit que les 30 derniers jours. iOS ne dit jamais qu'une donnée est refusée : elle ressemble à une donnée absente. Les autorisations se changent dans Réglages d'iOS, Confidentialité et sécurité, Santé, HAL.")
            }

            Section("Voir les données") {
                NavigationLink("Sommeil et récupération") { EcranSommeil() }
                NavigationLink("La dernière nuit en détail") { EcranNuit(jour: nil) }
                NavigationLink("Forme et corps") { EcranForme() }
                NavigationLink("Séances de la montre") { EcranSeancesMontre() }
                NavigationLink("Fréquence cardiaque du jour") { EcranFrequence() }
            }

            Section {
                NavigationLink("Apple Watch") { EcranMontre() }
            } footer: {
                Text("Les séances faites avec la montre arrivent par Santé. Une course prévue part sur la montre depuis sa séance.")
            }
        }
        .navigationTitle("Santé")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func couleur(_ donnee: EnvoiSante.Donnee) -> Color {
        switch donnee {
        case .sommeil, .nuit: Categorie.ia.couleur
        case .seances, .pas, .detailSeances, .trace, .vfc: Categorie.sport.couleur
        case .poids: Categorie.linge.couleur
        case .frequence: Categorie.alerte.couleur
        }
    }

    /// 5.10 : le premier envoi remonte tout l'historique, par morceaux. On voit
    /// où il en est ; « Tout renvoyer » repart du début sans rien doubler (SAN-3).
    private var historique: some View {
        let collecte = sante.collecte
        let fini = collecte.historiqueFini(sante.lues)
        let avancee = collecte.avancee(sante.lues)
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fini ? "Historique à jour" : "Premier envoi en cours")
                        .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    if collecte.enCours { ProgressView().controlSize(.small) }
                    Text(avancee.formatted(.percent.precision(.fractionLength(0)).locale(enFrancais)))
                        .texte(.titreWidget).foregroundStyle(Categorie.sport.couleur)
                }
                ProgressView(value: avancee).tint(Categorie.sport.couleur)
                let resume = collecte.resume(sante.lues)
                if !resume.isEmpty {
                    Text(resume).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                if let bilan = collecte.dernierBilan {
                    Text(bilan).texte(.legende).foregroundStyle(Palette.texteTertiaire)
                }
            }
            .padding(.vertical, 4)
            Button("Tout renvoyer depuis le début") { renvoyer = true }
                .disabled(collecte.enCours)
                .confirmationDialog("Tout renvoyer depuis le début ?", isPresented: $renvoyer,
                                    titleVisibility: .visible) {
                    Button("Tout renvoyer") {
                        collecte.toutRenvoyer()
                        Task { await sante.envoyer(raison: "tout renvoyer", budget: 60) }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("L'historique repart de zéro. Le serveur ne garde rien en double.")
                }
        } header: {
            Text("Historique")
        } footer: {
            Text("Il avance à chaque ouverture, et surtout quand l'iPhone est branché. Il reprend tout seul là où il s'est arrêté. Ensuite, seul le nouveau part.")
        }
    }

    private func coche(_ donnee: EnvoiSante.Donnee) -> Binding<Bool> {
        Binding {
            sante.lues.contains(donnee)
        } set: { oui in
            if oui { sante.lues.insert(donnee) } else { sante.lues.remove(donnee) }
            if donnee == .frequence {
                Task {
                    await sante.relireLaFrequence()
                    foyer.poserLaFrequence(sante.frequenceDuJour)
                }
            }
        }
    }
}

// MARK: - Mesures

extension MesureDemandee: Identifiable {}

/// Les mesures, type par type : la dernière, la courbe, l'historique. Une
/// mesure se saisit aussi hors de toute fenêtre de HAL (MES-4).
struct EcranMesures: View {
    @Environment(Foyer.self) private var foyer
    @State private var mesures: [MesureSaisie]?
    @State private var erreur: String?
    @State private var aSaisir: MesureDemandee?
    @State private var ouvert: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                // Le type se choisit dans la feuille (3.19).
                Button {
                    aSaisir = MesureDemandee(titre: "", consigne: "", jusquA: "", id: 0, type: "poids")
                } label: {
                    Label("Saisir une mesure", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true))

                if let mesures {
                    let types = TypeMesure.tous.filter { type in mesures.contains { $0.typeMesure == type } }
                    if types.isEmpty {
                        Text("Aucune mesure encore. HAL en demande une de temps en temps, et tu peux en noter une quand tu veux.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(types, id: \.self) { type in
                        carte(type, mesures.filter { $0.typeMesure == type })
                    }
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(Espace.marge)
        }
        .navigationTitle("Mesures")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(.clear, for: .navigation)
        .task { await charger() }
        .refreshable { await charger() }
        .sheet(item: $aSaisir, onDismiss: { Task { await charger() } }) { mesure in
            FeuilleMesure(mesure: mesure).presentationDetents([.fraction(0.8), .large]).feuilleEnVerre()
        }
    }

    private func carte(_ type: String, _ siennes: [MesureSaisie]) -> some View {
        let derniere = siennes[0]
        let deploye = ouvert == type
        return Button { withAnimation(.snappy) { ouvert = deploye ? nil : type } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(TypeMesure.libelle(type)).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    Text(TypeMesure.enClair(derniere.valeur, unite: derniere.unite))
                        .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                }
                Text("Le \(dateCourte(derniere.dateMesure))\(ecart(siennes))")
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                if siennes.count > 1 {
                    Courbe(points: siennes.reversed().map { PointSerie(date: $0.dateMesure, valeur: $0.valeur) },
                           couleur: Categorie.sport.couleur, hauteur: deploye ? 140 : 60)
                }
                if deploye {
                    ForEach(siennes) { mesure in
                        HStack {
                            Text(dateCourte(mesure.dateMesure)).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                            if let cote = mesure.cote {
                                Text(cote).texte(.legende).foregroundStyle(Palette.texteTertiaire)
                            }
                            Spacer()
                            Text(TypeMesure.enClair(mesure.valeur, unite: mesure.unite))
                                .texte(.legende).foregroundStyle(Palette.textePrincipal)
                        }
                    }
                }
            }
            .padding(Espace.interne)
            .frame(maxWidth: .infinity, alignment: .leading)
            .carte()
        }
        .buttonStyle(.plain)
    }

    /// L'écart avec la mesure d'avant, dans l'unité de la mesure.
    private func ecart(_ siennes: [MesureSaisie]) -> String {
        guard siennes.count > 1 else { return "" }
        let difference = siennes[0].valeur - siennes[1].valeur
        guard abs(difference) >= 0.05 else { return " · comme la fois d'avant" }
        let signe = difference > 0 ? "+" : "−"
        return " · \(signe)\(TypeMesure.enClair(abs(difference), unite: siennes[0].unite))"
    }

    private func charger() async {
        guard foyer.connecte else {
            mesures = []
            return
        }
        do {
            mesures = try await foyer.demander("GET", "appli/mesures")
            erreur = nil
        } catch {
            erreur = raison(error)
        }
    }
}

// MARK: - Séances de la montre

/// SAN-2 : tout ce que la montre a enregistré, avec son détail.
struct EcranSeancesMontre: View {
    @Environment(Foyer.self) private var foyer
    @State private var periode = 30
    @State private var historique: HistoriqueSante?
    @State private var erreur: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                Segmente(choix: [(7, "7 jours"), (30, "30 jours"), (90, "90 jours")], selection: $periode)
                if let historique {
                    if historique.seances.isEmpty {
                        Text("Aucune séance de la montre sur la période.")
                            .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    ForEach(historique.seances, id: \.self) { activite in
                        CarteActivite(activite: activite)
                    }
                } else if let erreur {
                    Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
                Text("Elles arrivent par Santé. Une séance de la montre compte la séance prévue du même jour comme faite.")
                    .texte(.legende).foregroundStyle(Palette.texteTertiaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Espace.marge)
        }
        .navigationTitle("Séances de la montre")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(.clear, for: .navigation)
        .task(id: periode) {
            do {
                historique = try await foyer.demander("GET", "appli/sante?jours=\(periode)")
                erreur = nil
            } catch {
                erreur = raison(error)
            }
        }
    }
}

/// Une séance de la montre en carte : durée, distance, allure, fréquence, énergie.
private struct CarteActivite: View {
    let activite: HistoriqueSante.Activite

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Discipline.nom(activite.discipline ?? activite.type)).texte(.titreWidget)
                    .foregroundStyle(Palette.textePrincipal)
                Spacer()
                Text(activite.debut.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                    .hour().minute().locale(enFrancais)))
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            HStack(spacing: Espace.gouttiere) {
                chiffre("Durée", activite.dureeSecondes.map { "\($0 / 60) min" })
                chiffre("Distance", activite.distanceM.map {
                    (Double($0) / 1000).formatted(.number.precision(.fractionLength(1)).locale(enFrancais)) + " km"
                })
                chiffre("Allure", activite.allureSKm.map { "\($0 / 60):\(String(format: "%02d", $0 % 60)) /km" })
            }
            HStack(spacing: Espace.gouttiere) {
                chiffre("FC moyenne", activite.fcMoyenne.map { "\($0) bpm" })
                chiffre("FC max", activite.fcMax.map { "\($0) bpm" })
                chiffre("Énergie", activite.energieKcal.map { "\($0) kcal" })
            }
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte()
    }

    private func chiffre(_ titre: String, _ valeur: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titre.uppercased()).texte(.etiquette).foregroundStyle(Palette.texteTertiaire)
            Text(valeur ?? "–").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
