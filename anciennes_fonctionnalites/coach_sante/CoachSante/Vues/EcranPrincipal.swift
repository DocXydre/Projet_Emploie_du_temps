import SwiftUI

struct EcranPrincipal: View {
    @EnvironmentObject private var synchro: Synchro
    @EnvironmentObject private var seance: SeanceEnCours
    @State private var reglagesOuverts = false
    @State private var dernierBilan: String?
    @State private var seanceOuverte = false

    var body: some View {
        NavigationStack {
            List {
                sectionMuscu
                sectionEnvoi
                sectionJours
                sectionSeances
                sectionJournal
            }
            .navigationTitle("Coach Santé")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { reglagesOuverts = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await synchro.relire() }
            .sheet(isPresented: $reglagesOuverts) {
                EcranReglages().environmentObject(synchro)
            }
            .onAppear { if !synchro.estConfiguree { reglagesOuverts = true } }
            .navigationDestination(isPresented: $seanceOuverte) {
                EcranSeance().environmentObject(seance)
            }
        }
    }

    /// SAI-14 : lancer une séance de musculation, ou reprendre celle en cours.
    private var sectionMuscu: some View {
        Section {
            Button {
                Task {
                    if !seance.enCours { await seance.demarrer() }
                    if seance.enCours { seanceOuverte = true }
                }
            } label: {
                HStack {
                    Label(seance.enCours ? "Reprendre ma séance" : "Lancer une séance de muscu",
                          systemImage: seance.enCours ? "play.circle.fill" : "dumbbell.fill")
                        .font(.headline)
                    Spacer()
                    if seance.occupe { ProgressView() }
                }
            }
            .disabled(seance.occupe || !synchro.estConfiguree)
            if let erreur = seance.erreur, !seanceOuverte {
                Text(erreur).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Musculation")
        } footer: {
            Text(seance.enCours
                 ? "\(seance.series.count) séries enregistrées pour l'instant."
                 : "Si le coach a prévu une séance de muscu aujourd'hui, c'est elle qui s'ouvre. "
                   + "Sinon, une séance libre.")
        }
    }

    private var sectionEnvoi: some View {
        Section {
            Button {
                Task { dernierBilan = await synchro.synchroniser(raison: "à la main") }
            } label: {
                HStack {
                    Label("Envoyer maintenant", systemImage: "arrow.up.heart")
                    Spacer()
                    if synchro.enCours { ProgressView() }
                }
            }
            .disabled(synchro.enCours)

            if let progression = synchro.progression {
                Text(progression).font(.footnote).foregroundStyle(.secondary)
            }
            if let dernierBilan {
                Text(dernierBilan).font(.footnote)
            }
            LabeledContent("Dernier envoi réussi",
                           value: synchro.dernierEnvoi.map { $0.formatted(date: .abbreviated,
                                                                           time: .shortened) }
                               ?? "jamais")
            if let expiration = Profil.expiration {
                let jours = Calendar.current.dateComponents([.day], from: Date(),
                                                            to: expiration).day ?? 0
                LabeledContent("L'appli expire",
                               value: expiration.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(jours <= 1 ? .red : .primary)
            }
        } footer: {
            Text("L'envoi se fait aussi à chaque ouverture, et parfois tout seul la nuit.")
        }
    }

    private var sectionJours: some View {
        Section("Ce que Santé donne, 7 derniers jours") {
            if synchro.jours.isEmpty {
                Text("Rien de lu pour l'instant. Tire vers le bas pour relire.")
                    .foregroundStyle(.secondary)
            }
            ForEach(synchro.jours) { jour in
                VStack(alignment: .leading, spacing: 4) {
                    Text(jour.jour.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.headline)
                    HStack(spacing: 14) {
                        valeur("figure.walk", jour.pas.map { "\($0)" })
                        valeur("heart", jour.fcRepos.map { "\($0) bpm" })
                        valeur("waveform.path.ecg", jour.vfcMs.map { "\(Int($0)) ms" })
                        valeur("bed.double", jour.sommeilMinutes.map { Format.duree(minutes: $0) })
                    }
                    .font(.footnote)
                }
            }
        }
    }

    /// Une valeur absente s.affiche « - », jamais 0 (SAN-5).
    private func valeur(_ icone: String, _ texte: String?) -> some View {
        Label(texte ?? "-", systemImage: icone)
            .foregroundStyle(texte == nil ? .secondary : .primary)
    }

    private var sectionSeances: some View {
        Section("Séances de la montre") {
            if synchro.seances.isEmpty {
                Text("Aucune séance sur ces sept jours.").foregroundStyle(.secondary)
            }
            ForEach(synchro.seances) { s in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(s.libelle), \(s.debut.formatted(date: .abbreviated, time: .shortened))")
                        .font(.headline)
                    HStack(spacing: 14) {
                        Text("\(s.dureeSecondes / 60) min")
                        if let d = s.distanceM {
                            Text(String(format: "%.2f km", Double(d) / 1000))
                        }
                        if let fc = s.fcMoyenne { Text("\(fc) bpm") }
                        if let kcal = s.energieKcal { Text("\(kcal) kcal") }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sectionJournal: some View {
        Section("Journal") {
            if synchro.journal.isEmpty {
                Text("Aucun envoi depuis l'ouverture.").foregroundStyle(.secondary)
            }
            ForEach(synchro.journal) { ligne in
                VStack(alignment: .leading) {
                    Text(ligne.quand.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(ligne.texte).font(.footnote)
                        .foregroundStyle(ligne.erreur ? .red : .primary)
                }
            }
        }
    }
}
