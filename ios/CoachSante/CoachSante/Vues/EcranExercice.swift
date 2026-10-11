import SwiftUI
import UIKit

/// Un exercice : ses séries du jour, la dernière fois, et la saisie de la
/// suivante. Après une série, les valeurs restent : la suivante se valide d'un
/// geste si rien ne change.
struct EcranExercice: View {
    let code: String
    let libelle: String
    let mesure: String
    let ligne: LignePrevue?

    @EnvironmentObject private var seance: SeanceEnCours
    // La charge se tape en texte : « 42,5 » comme « 42.5 ». Un champ lié à un
    // nombre ne se met à jour qu'en quittant le champ, trop tard pour le bouton.
    @State private var chargeTexte = "20"
    @State private var reps: Int = 10
    @State private var duree: Int = 30
    @State private var distance: Int = 500
    @State private var derniereFois: [SerieFaite] = []
    @State private var prerempli = false
    @FocusState private var saisieCharge: Bool

    private var faites: [SerieFaite] { seance.seriesDe(code) }
    private var enDuree: Bool { mesure == "duree" }
    private var enDistance: Bool { mesure == "distance" }

    var body: some View {
        Form {
            if let ligne {
                Section("Prévu") { Text(ligne.enClair) }
            }

            Section("Aujourd'hui") {
                if faites.isEmpty {
                    Text("Pas encore de série.").foregroundStyle(.secondary)
                }
                ForEach(faites) { serie in
                    LabeledContent("Série \(serie.numero)", value: serie.enClair)
                }
                .onDelete { positions in
                    let aSupprimer = positions.map { faites[$0] }
                    Task { for serie in aSupprimer { await seance.supprimer(serie) } }
                }
            }

            Section {
                if enDuree {
                    Stepper("Durée : \(duree) s", value: $duree, in: 5...1800, step: 5)
                } else if enDistance {
                    Stepper("Distance : \(distance) m", value: $distance, in: 25...20000, step: 25)
                } else {
                    HStack {
                        Text("Charge")
                        Spacer()
                        Button { changerCharge(-2.5) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        TextField("kg", text: $chargeTexte)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .frame(width: 70)
                            .focused($saisieCharge)
                        Text("kg").foregroundStyle(.secondary)
                        Button { changerCharge(2.5) } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    Stepper("Répétitions : \(reps)", value: $reps, in: 0...100)
                }
                Button {
                    saisieCharge = false
                    Task { await ajouter() }
                } label: {
                    HStack {
                        Label("Ajouter la série \(faites.count + 1)", systemImage: "plus")
                            .font(.headline)
                        Spacer()
                        if seance.occupe { ProgressView() }
                    }
                }
                .disabled(seance.occupe)
            } header: {
                Text("Nouvelle série")
            } footer: {
                if !enDuree && !enDistance {
                    Text("Une seule charge pour les deux côtés. Pour une série au poids du "
                         + "corps, laisse 0 kg.")
                }
            }

            if !derniereFois.isEmpty {
                Section("La dernière fois") {
                    Text(derniereFois.map(\.enClair).joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(libelle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("OK") { saisieCharge = false }
            }
        }
        .task {
            derniereFois = await seance.derniereFois(code)
            preremplir()
        }
    }

    /// La dernière série du jour, sinon la première de la dernière fois, sinon le
    /// prévu du coach.
    private func preremplir() {
        guard !prerempli else { return }
        prerempli = true
        let modele = faites.last ?? derniereFois.first
        if let c = modele?.chargeKg ?? ligne?.chargeKg { chargeTexte = Self.enTexte(c) }
        if let r = modele?.repetitions ?? ligne?.repsMax { reps = r }
        if let d = modele?.dureeSecondes ?? ligne?.dureeSecondes { duree = d }
        if let m = modele?.distanceM { distance = m }
    }

    private var charge: Double {
        Double(chargeTexte.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func changerCharge(_ pas: Double) {
        chargeTexte = Self.enTexte(max(charge + pas, 0))
    }

    static func enTexte(_ valeur: Double) -> String {
        valeur.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(valeur))
            : String(format: "%.2f", valeur)
                .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: ".", with: ",")
    }

    private func ajouter() async {
        let fait = await seance.ajouterSerie(
            code: code, ligne: ligne?.id,
            charge: enDuree || enDistance ? nil : charge,
            reps: enDuree || enDistance ? nil : reps,
            duree: enDuree ? duree : nil,
            distance: enDistance ? distance : nil)
        if fait {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}

/// La clôture : l'effort de 1 à 10, la durée, un mot, et l'avis du coach.
struct FinDeSeance: View {
    @EnvironmentObject private var seance: SeanceEnCours
    @Environment(\.dismiss) private var fermer
    @State private var effort: Double = 7
    @State private var minutes = 60
    @State private var commentaire = ""
    @State private var avisDuCoach = true
    @State private var reponse: String?

    private static let reperes = [
        1: "très facile", 2: "facile", 3: "facile", 4: "modéré", 5: "modéré",
        6: "soutenu", 7: "difficile", 8: "très difficile", 9: "presque à fond", 10: "à fond",
    ]

    var body: some View {
        NavigationStack {
            if let reponse {
                // La séance est close : la réponse du coach, puis retour à l'accueil.
                ScrollView {
                    Text(LocalizedStringKey(reponse))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Le coach")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Terminé") { fermer() }
                    }
                }
            } else {
                formulaire
            }
        }
        .interactiveDismissDisabled(seance.occupe)
    }

    private var formulaire: some View {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text("Effort : \(Int(effort)) sur 10, \(Self.reperes[Int(effort)] ?? "")")
                        Slider(value: $effort, in: 1...10, step: 1)
                    }
                    Stepper("Durée : \(minutes) min", value: $minutes, in: 1...300, step: 5)
                } header: {
                    Text("Ta séance")
                } footer: {
                    Text("\(seance.series.count) séries enregistrées.")
                }

                Section("Un mot pour le coach") {
                    TextField("Une gêne, une sensation, ce qui a changé…", text: $commentaire,
                              axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Toggle("Avoir l'avis du coach maintenant", isOn: $avisDuCoach)
                } footer: {
                    Text(avisDuCoach ? "Sa réponse arrive ici, en général en moins d'une minute."
                                     : "Il en parlera dans la synthèse de ce soir.")
                }

                if let erreur = seance.erreur {
                    Section {
                        Text(erreur).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            seance.erreur = nil
                            if let message = await seance.terminer(
                                effort: Int(effort), minutes: minutes,
                                commentaire: commentaire, avisDuCoach: avisDuCoach) {
                                reponse = message
                            }
                        }
                    } label: {
                        HStack {
                            Text("Clore la séance").font(.headline)
                            Spacer()
                            if seance.occupe { ProgressView() }
                        }
                    }
                    .disabled(seance.occupe)
                }
            }
            .navigationTitle("Fin de séance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { fermer() }.disabled(seance.occupe)
                }
            }
            .onAppear {
                if let debut = seance.debut {
                    minutes = max(Int(Date().timeIntervalSince(debut) / 60), 1)
                }
            }
    }
}
