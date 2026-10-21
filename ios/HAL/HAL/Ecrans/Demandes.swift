import SwiftUI

// Les demandes (ACC-5 à ACC-13) : ce que HAL ou un client MCP a demandé de
// changer au planning, aux tâches, aux absences. Rien ne change sans l'accord
// donné ici. Accepter part au bout de cinq secondes : « Annuler » le retient
// (ACC-7), comme une action du panneau de HAL.

private func motifDe(_ erreur: Error) -> String {
    (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
}

struct EcranDemandes: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @Environment(\.dismiss) private var fermer
    @State private var enCours: Set<Int> = []
    @State private var erreur: String?

    private struct Lot: Encodable { let ids: [Int] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                if foyer.demandes.isEmpty {
                    Text("Aucune demande n'attend ton accord.")
                        .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                }
                ForEach(foyer.demandes) { carte($0) }
                if foyer.demandes.count > 1 {
                    Button("Tout accepter") { differer(foyer.demandes.map(\.idDemande), "Demandes acceptées") {
                        try await foyer.agir("POST", "demandes/accepter",
                                             corps: ClientAPI.corps(Lot(ids: $0)))
                    } }
                    .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                }
                LigneErreur(texte: erreur)
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Demandes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { fermer() } } }
        .vuParHAL("Demandes à accepter")
    }

    private func carte(_ demande: DemandeAPI) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(demande.resume, systemImage: "hand.raised")
                .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(demande.auteur) : \(demande.motif)")
                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                .fixedSize(horizontal: false, vertical: true)
            if enCours.contains(demande.idDemande) {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    Button("Accepter") { differer([demande.idDemande], "Demande acceptée") { ids in
                        try await foyer.agir("POST", "demandes/\(ids[0])/accepter")
                    } }
                    .buttonStyle(.hal(.accent, pleineLargeur: true))
                    Button("Refuser") { Task { await refuser(demande) } }
                        .buttonStyle(.hal(.verre, pleineLargeur: true))
                }
            }
        }
        .padding(Espace.interne)
        .carte()
    }

    /// ACC-7 : l'accord part au bout de cinq secondes, sauf « Annuler ».
    private func differer(_ ids: [Int], _ annonce: String,
                          _ envoyer: @escaping ([Int]) async throws -> Void) {
        enCours.formUnion(ids)
        let tache = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            do {
                try await envoyer(ids)
                erreur = nil
            } catch {
                erreur = motifDe(error)
            }
            enCours.subtract(ids)
        }
        annoncer(annonce, annuler: {
            tache.cancel()
            enCours.subtract(ids)
        })
    }

    private func refuser(_ demande: DemandeAPI) async {
        do {
            try await foyer.agir("POST", "demandes/\(demande.idDemande)/refuser")
            annoncer("Demande refusée")
        } catch {
            erreur = motifDe(error)
        }
    }
}
