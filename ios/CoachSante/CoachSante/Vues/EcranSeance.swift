import SwiftUI

/// La séance en cours : ce qui était prévu, ce qui est fait, et la boucle
/// « choisir un exercice, ajouter ses séries, revenir » jusqu'à la clôture.
struct EcranSeance: View {
    @EnvironmentObject private var seance: SeanceEnCours
    @Environment(\.dismiss) private var fermer
    @State private var clotureOuverte = false

    var body: some View {
        List {
            Section {
                if let debut = seance.debut {
                    TimelineView(.periodic(from: debut, by: 1)) { contexte in
                        LabeledContent("Durée", value: Self.chrono(depuis: debut, a: contexte.date))
                            .monospacedDigit()
                    }
                }
                LabeledContent("Séries", value: "\(seance.series.count)")
            }

            if !seance.prevu.isEmpty {
                Section("Prévu par le coach") {
                    ForEach(seance.prevu) { ligne in
                        NavigationLink {
                            EcranExercice(code: ligne.code, libelle: ligne.libelle,
                                          mesure: ligne.mesure, ligne: ligne)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(ligne.libelle)
                                    Spacer()
                                    let faites = seance.seriesDe(ligne.code).count
                                    if faites > 0 {
                                        Text("\(faites)/\(ligne.series ?? faites)")
                                            .foregroundStyle(faites >= (ligne.series ?? faites)
                                                             ? Color.green : Color.secondary)
                                    }
                                }
                                Text(ligne.enClair).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Fait") {
                let horsPrevu = seance.parExercice.filter { groupe in
                    !seance.prevu.contains { $0.code == groupe.code }
                }
                if seance.series.isEmpty {
                    Text("Aucune série pour l'instant.").foregroundStyle(.secondary)
                }
                ForEach(horsPrevu) { groupe in
                    NavigationLink {
                        EcranExercice(code: groupe.code, libelle: groupe.libelle,
                                      mesure: seance.exercice(code: groupe.code)?.mesure
                                          ?? "charge_reps", ligne: nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(groupe.libelle)
                            Text(groupe.series.map(\.enClair).joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink {
                    ChoixExercice()
                } label: {
                    Label("Ajouter un exercice", systemImage: "plus.circle.fill")
                }
            }

            Section {
                Button {
                    clotureOuverte = true
                } label: {
                    Label("Terminer la séance", systemImage: "flag.checkered")
                }
                .disabled(seance.occupe)
            } footer: {
                Text("Tu donnes ton effort, et le coach peut te répondre tout de suite.")
            }
        }
        .navigationTitle(seance.titre)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await seance.recharger() }
        .task { await seance.recharger() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Quitter sans clore", role: .destructive) {
                        seance.oublier()
                        fermer()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $clotureOuverte, onDismiss: {
            // La séance est close : on revient à l'écran d'accueil.
            if !seance.enCours { fermer() }
        }) {
            FinDeSeance().environmentObject(seance)
        }
        .alert("Oups", isPresented: Binding(
            get: { seance.erreur != nil }, set: { if !$0 { seance.erreur = nil } })
        ) {
            Button("OK") { seance.erreur = nil }
        } message: {
            Text(seance.erreur ?? "")
        }
    }

    static func chrono(depuis debut: Date, a maintenant: Date) -> String {
        let secondes = max(Int(maintenant.timeIntervalSince(debut)), 0)
        let h = secondes / 3600, m = secondes % 3600 / 60, s = secondes % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Le catalogue, à chercher par nom. Les exercices faits récemment d'abord.
struct ChoixExercice: View {
    @EnvironmentObject private var seance: SeanceEnCours
    @State private var recherche = ""

    private var filtres: [Exercice] {
        let mots = recherche.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                     locale: .current)
        guard !mots.isEmpty else { return seance.catalogue }
        return seance.catalogue.filter {
            $0.libelle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(mots)
        }
    }

    private var recents: [Exercice] {
        filtres.filter { $0.derniereSaisie != nil }
            .sorted { ($0.derniereSaisie ?? "") > ($1.derniereSaisie ?? "") }
            .prefix(8).map { $0 }
    }

    private struct Groupe: Identifiable {
        let nom: String
        let exercices: [Exercice]
        var id: String { nom }
    }

    private var parGroupe: [Groupe] {
        Dictionary(grouping: filtres, by: \.groupe)
            .map { Groupe(nom: $0.key, exercices: $0.value.sorted { $0.libelle < $1.libelle }) }
            .sorted { $0.nom < $1.nom }
    }

    var body: some View {
        List {
            if !recents.isEmpty {
                Section("Récents") {
                    ForEach(recents) { lien($0) }
                }
            }
            ForEach(parGroupe) { groupe in
                Section(groupe.nom.replacingOccurrences(of: "_", with: " ").capitalized) {
                    ForEach(groupe.exercices) { lien($0) }
                }
            }
        }
        .searchable(text: $recherche, prompt: "Chercher un exercice")
        .navigationTitle("Exercice")
        .overlay {
            if seance.catalogue.isEmpty { ProgressView() }
        }
        .task { if seance.catalogue.isEmpty { await seance.chargerCatalogue() } }
    }

    private func lien(_ exercice: Exercice) -> some View {
        NavigationLink {
            EcranExercice(code: exercice.code, libelle: exercice.libelle,
                          mesure: exercice.mesure,
                          ligne: seance.prevu.first { $0.code == exercice.code })
        } label: {
            Text(exercice.libelle)
        }
    }
}
