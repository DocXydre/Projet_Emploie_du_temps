import SwiftUI

// Le sport sans montre (MON-7 à MON-14) : la note d'effort d'une course reçue
// d'une autre appli que la montre, et la course déclarée à la main.

// MARK: - L'effort de 1 à 10

/// SAI-4, MON-11 : dix cases, la note choisie en couleur, et ce qu'elle veut dire.
struct ChoixEffort: View {
    @Binding var effort: Int

    var body: some View {
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
            Text("\(effort) · \(Self.libelle(effort))").texte(.corps).foregroundStyle(Palette.textePrincipal)
        }
    }

    static func libelle(_ effort: Int) -> String {
        switch effort {
        case ...3: "facile, il en restait beaucoup"
        case 4...5: "modéré"
        case 6...7: "dur mais propre"
        case 8...9: "très dur, presque rien en réserve"
        default: "maximal"
        }
    }
}

// MARK: - 3.27 Effort d'une course

/// MON-11 : une course reçue sans la montre attend sa note. Elle devient le
/// bilan de la séance ; HAL la lit à la synthèse, sans être appelé.
struct CarteEffort: View {
    let course: EtatSport.EffortADonner
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(\.annoncer) private var annoncer
    @State private var note = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Quel effort ?", systemImage: "gauge.with.dots.needle.50percent")
                    .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                Spacer()
                Text(EnFrancais.jour(course.debut)).texte(.legende).foregroundStyle(Palette.texteTertiaire)
            }
            Text(course.enClair)
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                .fixedSize(horizontal: false, vertical: true)
            ChoixEffort(effort: $note)
            Button("Noter l'effort") {
                foyer.noterEffort(note, seance: course.idOccurrence, file: file)
                annoncer("Effort \(note) noté : HAL en tient compte ce soir")
            }
            .buttonStyle(.hal(.accent, pleineLargeur: true))
        }
        .padding(Espace.interne)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carte(rayon: Rayon.controle)
    }
}

extension Module {
    /// MON-11 : passe en tête d'Aujourd'hui tant qu'une course attend sa note (WID-6).
    static let effortADonner = Module(
        id: "effortADonner", nom: "Effort à donner", icone: "gauge.with.dots.needle.50percent",
        categorie: .sport, tailles: [.moyen],
        widget: { _ in AnyView(WidgetEffortADonner()) }
    )
}

/// La course reçue sans la montre, et sa note en un geste.
struct WidgetEffortADonner: View {
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        CoquilleWidget(.effortADonner, droite: foyer.effortsADonner.first.map { EnFrancais.jour($0.debut) }) {
            if let course = foyer.effortsADonner.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text(course.enClair).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                    Text("Quel effort, de 1 à 10 ?").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        ForEach(1...10, id: \.self) { note in
                            Button {
                                foyer.noterEffort(note, seance: course.idOccurrence, file: file)
                                annoncer("Effort \(note) noté : \(ChoixEffort.libelle(note))")
                            } label: {
                                Text("\(note)").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                                    .frame(maxWidth: .infinity, minHeight: 32)
                                    .background(Palette.verreTeinte,
                                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Effort \(note) sur 10")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 3.26 Course faite à la main

/// MON-12 : une course ou du cardio faits sans rien qui les enregistre. Depuis
/// une course prévue, ou depuis l'ajout rapide. La séance se rattache côté
/// serveur comme une séance reçue de Santé, et porte sa note d'effort.
struct FormulaireCourseALaMain: View {
    @Environment(FileAttente.self) private var file
    @Environment(\.dismiss) private var fermer
    @Environment(\.fermerFeuille) private var fermerFeuille
    @Environment(\.annoncer) private var annoncer
    /// Vrai depuis une course prévue : la discipline est déjà dite.
    private let depuisUneSeance: Bool
    @State private var discipline: String
    @State private var debut: Date
    @State private var duree: Double
    @State private var distance = ""
    @State private var terrain: String?
    @State private var effort = 5
    @State private var commentaire = ""

    private static let terrains = [("route", "Route"), ("ville", "Ville"), ("foret", "Forêt"),
                                   ("trail", "Trail"), ("piste", "Piste"), ("tapis", "Tapis")]

    init(prevue: DetailSeance? = nil) {
        depuisUneSeance = prevue != nil
        let minutes = Double(prevue?.seance.dureeMinutes ?? 40)
        _discipline = State(initialValue: prevue?.seance.discipline == "cardio" ? "cardio" : "course")
        _duree = State(initialValue: minutes)
        // Le départ prévu s'il est passé, sinon une course qui vient de finir.
        let prevu = prevue?.seance.debut.flatMap { $0.addingTimeInterval(minutes * 60) <= .now ? $0 : nil }
        _debut = State(initialValue: prevu ?? .now.addingTimeInterval(-minutes * 60))
    }

    private var metres: Int? {
        Double(distance.replacingOccurrences(of: ",", with: ".")).map { Int(($0 * 1000).rounded()) }
            .flatMap { $0 > 0 ? $0 : nil }
    }

    /// Une course se déclare une fois finie.
    private var finie: Bool { debut.addingTimeInterval(duree * 60) <= .now.addingTimeInterval(60) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                if !depuisUneSeance {
                    EnTeteGroupe(texte: "Discipline")
                    HStack(spacing: 8) {
                        PuceChoix(texte: "Course", choisie: discipline == "course") { discipline = "course" }
                        PuceChoix(texte: "Cardio", choisie: discipline == "cardio") { discipline = "cardio" }
                    }
                }
                VStack(spacing: 0) {
                    HStack {
                        Text("Départ").texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        DatePicker("Départ", selection: $debut, in: Date.now.addingTimeInterval(-28 * 86_400)...Date.now)
                            .labelsHidden()
                    }
                    .padding(.vertical, 8)
                    Divider().overlay(Palette.verreBord)
                    HStack {
                        Text("Durée").texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        Compteur(titre: "min", valeur: $duree, pas: 1, bornes: 1...600, compact: true, saisie: true)
                            .frame(width: 200)
                    }
                    .padding(.vertical, 6)
                    Divider().overlay(Palette.verreBord)
                    HStack {
                        Text("Distance").texte(.corps).foregroundStyle(Palette.textePrincipal)
                        Spacer()
                        TextField("si tu la connais", text: $distance)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .texte(.corps).foregroundStyle(Palette.textePrincipal)
                            .frame(width: 130)
                        Text("km").texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    }
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, Espace.interne)
                .carte(rayon: Rayon.controle)

                if discipline == "course" {
                    // Le terrain change l'allure tenable (chapitre 5.3 du dossier).
                    EnTeteGroupe(texte: "Terrain")
                    VStack(alignment: .leading, spacing: 8) {
                        terrains(Array(Self.terrains.prefix(3)))
                        terrains(Array(Self.terrains.suffix(3)))
                    }
                }

                EnTeteGroupe(texte: "Effort")
                ChoixEffort(effort: $effort)
                    .padding(Espace.interne)
                    .carte(rayon: Rayon.controle)

                TextField("Une douleur, un parcours, une forme du jour…", text: $commentaire, axis: .vertical)
                    .texte(.corps).foregroundStyle(Palette.textePrincipal)
                    .lineLimit(2...4)
                    .padding(Espace.interne)
                    .carte(rayon: Rayon.controle)

                if !finie {
                    Label("Une course se déclare une fois finie : avance le départ ou raccourcis la durée.",
                          systemImage: "exclamationmark.circle")
                        .texte(.corps).foregroundStyle(Categorie.alerte.couleur)
                }
                Button("Enregistrer la \(discipline == "course" ? "course" : "séance")") { enregistrer() }
                    .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                    .disabled(!finie)
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle(discipline == "course" ? "Course faite" : "Cardio fait")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Toucher le terrain choisi le retire : il n'est pas obligatoire.
    private func terrains(_ choix: [(String, String)]) -> some View {
        HStack(spacing: 8) {
            ForEach(choix, id: \.0) { un in
                PuceChoix(texte: un.1, choisie: terrain == un.0) {
                    terrain = terrain == un.0 ? nil : un.0
                }
            }
        }
    }

    private struct Demande: Encodable {
        let cleClient: UUID
        let discipline: String
        let debut: Date
        let dureeMinutes: Int
        let effort: Int
        let distanceM: Int?
        let terrain: String?
        let commentaire: String?
    }

    /// Par la file d'attente : sans réseau, elle part au retour (APP-3), et la
    /// clé de l'appareil rend l'envoi répétable (SAI-9).
    private func enregistrer() {
        let demande = Demande(
            cleClient: UUID(), discipline: discipline, debut: debut, dureeMinutes: Int(duree),
            effort: effort, distanceM: metres, terrain: discipline == "course" ? terrain : nil,
            commentaire: commentaire.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : commentaire)
        file.ajouter(methode: "POST", chemin: "seances/course-a-la-main",
                     corps: try? ClientAPI.encodeur.encode(demande))
        annoncer(discipline == "course" ? "Course enregistrée : HAL la lit ce soir" : "Séance enregistrée")
        (fermerFeuille?.fermer ?? { fermer() })()
    }
}
