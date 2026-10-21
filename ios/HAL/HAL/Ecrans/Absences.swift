import SwiftUI

/// 4.7 : où chacun est, ce qui vient (les absences, les voyages lus dans les
/// billets), et de quoi partir ou rentrer (ABS, BIL).
struct EcranAbsences: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.annoncer) private var annoncer
    @State private var jePars = false
    @State private var prevue = false
    @State private var releve = false
    @State private var confirmerRelecture = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                statut
                let aVenir = foyer.absences.filter { $0.fin > .now }
                if !aVenir.isEmpty {
                    EnTeteGroupe(texte: "À venir")
                    VStack(spacing: 0) {
                        ForEach(Array(aVenir.enumerated()), id: \.element.id) { rang, absence in
                            ligne(absence)
                            if rang < aVenir.count - 1 { Divider().overlay(Palette.verreBord) }
                        }
                    }
                    .carte(rayon: Rayon.controle)
                }
                if foyer.moi.estAdministrateur { billets }
            }
            .padding(Espace.marge)
        }
        .scrollIndicators(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Absences et voyages")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $jePars) {
            FeuilleJePars().presentationDetents([.fraction(0.82), .large]).feuilleEnVerre()
        }
        .sheet(isPresented: $prevue) {
            NavigationStack { FormulaireAbsence() }.feuilleEnVerre()
        }
    }

    /// « Tu es à la maison · Lorette aussi », ou l'absence en cours.
    private var statut: some View {
        let moi = foyer.absences.first { $0.pour == foyer.moi && $0.enCours }
        let autre = foyer.autre.flatMap { autre in foyer.absences.first { $0.pour == autre && $0.enCours } }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: moi == nil ? "house" : "mappin")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 38, height: 38)
                    .background(moi == nil ? Categorie.menage.couleur : Categorie.ia.couleur,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(moi.map { "Tu es en voyage\($0.lieu.map { " · \($0)" } ?? "")" } ?? "Tu es à la maison")
                        .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    if let nom = foyer.autre?.nom {
                        Text(autre.map { "\(nom) est en voyage\($0.lieu.map { " · \($0)" } ?? "")" }
                             ?? (moi == nil ? "\(nom) aussi" : "\(nom) est à la maison"))
                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                }
            }
            HStack {
                if moi == nil {
                    Button("Je pars") { jePars = true }.buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                } else {
                    Button("Je suis de retour") { Task { await rentrer() } }
                        .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                }
                Button("Absence prévue") { prevue = true }.buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
            }
        }
        .padding(Espace.interne)
        .carte()
    }

    private func ligne(_ absence: Absence) -> some View {
        let mienne = absence.pour == foyer.moi
        let train = absence.origine == "trajet"
        let jours = max(1, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: absence.debut),
                                                          to: Calendar.current.startOfDay(for: absence.fin)).day ?? 1)
        let titre = [mienne ? nil : absence.pour.nom, absence.lieu ?? "Absence",
                     "\(EnFrancais.jour(absence.debut)) → \(EnFrancais.jour(absence.fin))"]
            .compactMap { $0 }.joined(separator: " · ")
        let detail = mienne
            ? (train ? "Billet SNCF · gèle le planning ces \(jours) jour\(jours > 1 ? "s" : "")"
                     : "Posée à la main · tes tâches passent aux autres")
            : "Ses tâches reviennent à toi ces jours-là"
        return HStack(spacing: 12) {
            Image(systemName: train ? "tram.fill" : "mappin.and.ellipse")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(train ? Categorie.travail.couleur : Palette.texteSecondaire,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(titre).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !mienne {
                Avatar(nom: absence.pour.nom, couleur: foyer.couleur(de: absence.pour), taille: 26)
            }
        }
        .padding(.horizontal, Espace.interne)
        .padding(.vertical, 10)
        .contextMenu {
            if mienne {
                Button("Annuler cette absence", systemImage: "trash", role: .destructive) {
                    Task { await annuler(absence) }
                }
            }
        }
    }

    /// BIL : les confirmations d'achat SNCF, relevées dans la boîte du serveur.
    private var billets: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "envelope").foregroundStyle(Palette.texteSecondaire)
                Text("Billets SNCF par courriel").texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            }
            HStack(spacing: 10) {
                Button(releve ? "Relève…" : "Relever la boîte") { Task { await relever() } }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
                Button("Tout relire") { confirmerRelecture = true }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
            }
            .disabled(releve)
            .confirmationDialog("Relire tous les billets des 120 derniers jours ?",
                                isPresented: $confirmerRelecture, titleVisibility: .visible) {
                Button("Tout relire") { Task { await relever(toutRelire: true) } }
            }
        }
        .padding(Espace.interne)
        .carte()
    }

    private func rentrer() async {
        do {
            try await foyer.agir("POST", "absences/retour")
            annoncer("Bon retour : tes tâches reviennent")
        } catch {
            annoncer((error as? ErreurAPI)?.message ?? "Impossible pour l'instant")
        }
    }

    private func annuler(_ absence: Absence) async {
        do {
            try await foyer.agir("DELETE", "absences/\(absence.id)?replacer=true")
            annoncer("Absence annulée")
        } catch {
            annoncer((error as? ErreurAPI)?.message ?? "Annulation impossible")
        }
    }

    /// « Tout relire » oublie d'abord les courriels récents, lus ou non, pour
    /// que la relève les reprenne tous (après une correction du lecteur).
    private func relever(toutRelire: Bool = false) async {
        releve = true
        defer { releve = false }
        do {
            if toutRelire { try await foyer.agir("DELETE", "trajets/courriels") }
            try await foyer.agir("POST", "trajets/courriels")
            annoncer("Boîte relevée")
        } catch {
            annoncer((error as? ErreurAPI)?.message ?? "Relève impossible")
        }
    }
}

/// 4.8 : je pars maintenant, retour inconnu ou à une date, et ce qui doit être
/// fait avant (ABS-6, ABS-7, TAC-18). Au retour, les tâches reviennent (ABS-8).
struct FeuilleJePars: View {
    @Environment(Foyer.self) private var foyer
    @Environment(\.dismiss) private var fermer
    @Environment(\.annoncer) private var annoncer
    @State private var lieu = ""
    @State private var maintenant = true
    @State private var retourInconnu = true
    @State private var depart = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var retour = Calendar.current.date(byAdding: .day, value: 2, to: .now) ?? .now
    @State private var envoi = false
    @State private var erreur: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Espace.gouttiere) {
                HStack {
                    Text("Je pars").texte(.titre).foregroundStyle(Palette.textePrincipal)
                    Spacer()
                    BoutonRond("xmark", libelle: "Fermer") { fermer() }
                }
                EnTeteGroupe(texte: "Où")
                HStack(spacing: 8) {
                    Image(systemName: "mappin").foregroundStyle(Palette.texteSecondaire)
                    TextField("Lusse, chez mes parents…", text: $lieu)
                        .texte(.corps).foregroundStyle(Palette.textePrincipal)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .verreControle(Capsule(), interactif: false)
                Segmente(choix: [(true, "Maintenant"), (false, "Plus tard")], selection: $maintenant)
                VStack(spacing: 0) {
                    if !maintenant {
                        ligneDate("Départ", $depart, depuis: .now)
                        Divider().overlay(Palette.verreBord)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Retour inconnu").texte(.corps).foregroundStyle(Palette.textePrincipal)
                            Text("jusqu'à ce que tu dises « je suis de retour »")
                                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        }
                        Spacer()
                        Toggle("Retour inconnu", isOn: $retourInconnu).labelsHidden()
                            .tint(Categorie.sport.couleur)
                    }
                    .padding(.vertical, 10)
                    .disabled(!maintenant)
                    if !retourInconnu || !maintenant {
                        Divider().overlay(Palette.verreBord)
                        ligneDate("Retour", $retour, depuis: maintenant ? .now : depart)
                    }
                }
                .padding(.horizontal, Espace.interne)
                .carte(rayon: Rayon.controle)
                let avant = avantDePartir
                if !avant.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AVANT DE PARTIR, POUR TOI").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                        ForEach(avant, id: \.self) { titre in
                            HStack(spacing: 10) {
                                Circle().fill(Categorie.menage.couleur).frame(width: 7, height: 7)
                                Text(titre).texte(.corps).foregroundStyle(Palette.textePrincipal)
                            }
                        }
                    }
                    .padding(Espace.interne)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .carte(rayon: Rayon.controle)
                }
                if let erreur {
                    Label(erreur, systemImage: "exclamationmark.circle")
                        .texte(.corps).foregroundStyle(Categorie.alerte.couleur)
                }
                Button { Task { await partir() } } label: {
                    HStack {
                        if envoi { ProgressView() }
                        Text(maintenant ? "Je pars" : "Poser l'absence")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true, grand: true))
                .disabled(envoi)
            }
            .padding(Espace.marge)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: maintenant) { _, nouveau in if !nouveau { retourInconnu = false } }
    }

    private func ligneDate(_ titre: String, _ date: Binding<Date>, depuis: Date) -> some View {
        HStack {
            Text(titre).texte(.corps).foregroundStyle(Palette.textePrincipal)
            Spacer()
            DatePicker(titre, selection: date, in: depuis...).labelsHidden()
        }
        .padding(.vertical, 8)
    }

    /// TAC-18 : ce que le planning a posé avant un départ, sinon mes tâches du jour.
    private var avantDePartir: [String] {
        let posees = foyer.complements.planning
            .filter { $0.idUtilisateur == foyer.moi.id && ($0.motif ?? "").hasPrefix("Avant de partir") }
            .map(\.libelle)
        if !posees.isEmpty { return Array(Set(posees)).sorted() }
        guard maintenant else { return [] }
        return foyer.tachesDuJour.filter { $0.pourQui == foyer.moi && !$0.faite }.map(\.titre)
    }

    private struct Absence: Encodable {
        let debut: Date
        let fin: Date
        let lieu: String?
    }

    private func partir() async {
        envoi = true
        erreur = nil
        defer { envoi = false }
        let ou = lieu.trimmingCharacters(in: .whitespaces)
        do {
            if maintenant && retourInconnu {
                let parametre = ou.isEmpty ? "" : "?lieu=" + (ou.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
                try await foyer.agir("POST", "absences/depart" + parametre)
            } else {
                let debut = maintenant ? Date.now : depart
                guard retour > debut else {
                    erreur = "Le retour doit venir après le départ."
                    return
                }
                try await foyer.agir("POST", "absences?replacer=true", corps: ClientAPI.corps(
                    Absence(debut: debut, fin: retour, lieu: ou.isEmpty ? nil : ou)))
            }
            annoncer(maintenant ? "Bon voyage : tes tâches passent aux autres" : "Absence posée")
            fermer()
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
