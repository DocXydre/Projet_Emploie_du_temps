import Foundation
import Observation

/// Les états qu'on peut forcer pour essayer l'appli sans serveur
/// (Réglages, Essais). Ils ne valent qu'en démonstration.
struct Essais: Hashable {
    var horsReseau = false
    var modeAllege = false
    var absence = false
    var pause = false
    var conflit = true
    var ajustement = false
    var mesure = false
    var jourDeMuscu = false
    var foyerVide = false
}

/// D'où viennent les données : les données fictives, ou le serveur.
enum Source {
    case demonstration
    case serveur(ClientAPI)
}

/// Les données du foyer que lisent les modules. Une seule source pour toute
/// l'appli : les widgets ne calculent rien, ils affichent (WID-8).
///
/// Connecté, Aujourd'hui et Maison viennent du serveur (lot 5). Le sport, la
/// santé et HAL restent fictifs jusqu'aux lots 6 et 7.
@MainActor
@Observable
final class Foyer {
    var essais = Essais()
    private(set) var source: Source = .demonstration

    private(set) var moi: Membre
    private(set) var autre: Membre?
    private(set) var membres: [Membre]
    private(set) var evenements: [Evenement]
    var taches: [Tache]
    private(set) var conflitDuServeur: Conflit?
    private(set) var absences: [Absence] = []
    private(set) var allegements: [Allegement] = []
    private(set) var propositions: [Proposition] = []
    private(set) var minutesFaites: [Int: Int] = [:]
    private(set) var droits = Droits(ajouter: true, modifier: true)
    private(set) var orbeADire = false
    private(set) var chat: EtatChat
    /// L'onglet Sport tel que le serveur l'a rendu (lot 6).
    private(set) var sportDuServeur: EtatSport?

    private(set) var semaine: SemaineSport
    private(set) var forme: Forme
    private(set) var frequenceDuJour: [PointSerie]
    private(set) var seance: SeanceDuJour
    private(set) var conflitEnCours: Conflit
    private(set) var ajustementEnCours: Ajustement
    private(set) var mesureEnCours: MesureDemandee
    private(set) var objectif: Objectif
    private(set) var dernierMotDeHAL: String

    /// Le dernier chargement réussi, et ce qui a empêché le suivant. L'heure est
    /// gardée avec les données : hors réseau, l'appli dit de quand elles datent (APP-2).
    private(set) var misAJour: Date? {
        didSet { UserDefaults.standard.set(misAJour, forKey: "foyer.mis_a_jour") }
    }
    private(set) var erreur: String?
    /// Le dernier échec est venu du réseau ou d'un serveur coupé (8.9).
    private(set) var injoignable = false
    /// Le serveur ne reconnaît plus la clé : compte retiré, ou clé renouvelée (CNX-6).
    private(set) var cleRefusee = false
    private(set) var charge = false

    /// 8.6 à 8.8 : mes calendriers suivis et les tâches du foyer. Inconnus tant
    /// que le serveur n'a pas répondu.
    private(set) var calendriersSuivis: Int?
    private(set) var tachesDuFoyer: Int?

    /// Les tâches cochées dont l'envoi attend encore la fin du délai d'annulation.
    private var enSuspens: [Int: Task<Void, Never>] = [:]

    private let apercu: Apercu

    init(apercu: Apercu = Apercu()) {
        self.apercu = apercu
        moi = apercu.moi
        autre = apercu.autre
        membres = [apercu.moi] + [apercu.autre].compactMap { $0 }
        evenements = apercu.evenements
        taches = apercu.taches
        semaine = apercu.semaine
        forme = apercu.forme
        frequenceDuJour = apercu.frequence
        seance = apercu.seance
        conflitEnCours = apercu.conflit
        ajustementEnCours = apercu.ajustement
        mesureEnCours = apercu.mesure
        objectif = apercu.objectif
        chat = apercu.chat
        dernierMotDeHAL = apercu.dernierMotDeHAL
    }

    var connecte: Bool {
        if case .serveur = source { return true }
        return false
    }

    var client: ClientAPI? {
        if case .serveur(let client) = source { return client }
        return nil
    }

    // MARK: Brancher et charger

    /// Passe sur le serveur : l'état gardé sur le téléphone s'affiche tout de
    /// suite, le chargement suit.
    func brancher(_ client: ClientAPI) {
        source = .serveur(client)
        if let garde = Self.lireLeCache() {
            appliquer(garde)
            misAJour = UserDefaults.standard.object(forKey: "foyer.mis_a_jour") as? Date
        }
        if let garde: EtatSport = Self.lire("etat-du-sport.json") { appliquer(garde) }
        Task { await charger() }
    }

    /// Revient aux données fictives.
    func debrancher() {
        source = .demonstration
        Self.effacerLeCache()
        moi = apercu.moi
        autre = apercu.autre
        membres = [apercu.moi] + [apercu.autre].compactMap { $0 }
        evenements = apercu.evenements
        taches = apercu.taches
        chat = apercu.chat
        conflitDuServeur = nil
        sportDuServeur = nil
        semaine = apercu.semaine
        forme = apercu.forme
        frequenceDuJour = apercu.frequence
        objectif = apercu.objectif
        try? FileManager.default.removeItem(at: Self.fichier("etat-du-sport.json"))
        absences = []
        allegements = []
        propositions = []
        minutesFaites = [:]
        orbeADire = false
        misAJour = nil
        erreur = nil
        injoignable = false
        cleRefusee = false
        charge = false
        calendriersSuivis = nil
        tachesDuFoyer = nil
    }

    func charger() async {
        guard let client else { return }
        do {
            let etat: EtatDuJour = try await client.requete("GET", "appli/aujourdhui")
            appliquer(etat)
            Self.ecrireLeCache(etat)
            misAJour = .now
            erreur = nil
            injoignable = false
            cleRefusee = false
        } catch let refus as ErreurAPI {
            erreur = refus.message
            injoignable = refus.injoignable
            cleRefusee = refus.statut == 401
        } catch {
            erreur = "Chargement impossible"
            injoignable = true
        }
        // Le sport à part : son échec n'empêche pas la maison de s'afficher.
        if let sport: EtatSport = try? await client.requete("GET", "appli/sport") {
            appliquer(sport)
            Self.ecrire(sport, "etat-du-sport.json")
        }
        publierPourLesWidgets()
    }

    /// La fréquence cardiaque du jour, lue dans Santé par l'appareil (3.15).
    func poserLaFrequence(_ points: [PointSerie]) {
        guard connecte, !points.isEmpty else { return }
        frequenceDuJour = points
    }

    private func appliquer(_ sport: EtatSport) {
        sportDuServeur = sport
        let prochaine = sport.semaine.prochaine.map { seance in
            let jour = seance.debut.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "fr_FR")))
            let heure = seance.debut.formatted(date: .omitted, time: .shortened)
            let quoi = (seance.typeSeance ?? "").isEmpty || seance.typeSeance == "libre"
                ? Discipline.nom(seance.discipline) : (seance.typeSeance ?? "")
            return "\(jour.capitalized) \(heure) · \(quoi)"
        }
        semaine = SemaineSport(faites: sport.semaine.faites, prevues: sport.semaine.prevues,
                               prochaine: prochaine)
        let jour = sport.forme.first
        forme = Forme(sommeilMinutes: jour?.sommeilMinutes, fcRepos: jour?.fcRepos,
                      vfc: jour?.vfcMs.map { Int($0.rounded()) }, pas: jour?.pas, tendanceFC: nil)
        if let lu = sport.objectif {
            let total = lu.echeance.flatMap { fin in lu.dateCreation.map { fin.timeIntervalSince($0) } } ?? 0
            let ecoule = lu.dateCreation.map { Date.now.timeIntervalSince($0) } ?? 0
            objectif = Objectif(titre: lu.libelle, joursRestants: lu.joursRestants ?? 0,
                                avancee: total > 0 ? min(1, max(0, ecoule / total)) : 0)
        }
    }

    /// La séance de musculation du jour qui reste à faire, prête sans réseau (SAI-10).
    var seanceDuJour: DetailSeance? {
        sportDuServeur?.seancesDuJour.first { !$0.close && $0.seance.discipline == "musculation" }
    }

    var objectifEnCours: Objectif? {
        connecte ? (sportDuServeur?.objectif == nil ? nil : objectif) : objectif
    }

    private func membre(_ id: Int?, parmi liste: [Membre]) -> Membre {
        liste.first { $0.id == id } ?? moi
    }

    private func appliquer(_ etat: EtatDuJour) {
        let lus = etat.membres.map {
            Membre(id: $0.id, nom: $0.nom, estAdministrateur: $0.administrateur, pseudo: $0.pseudo)
        }
        if let mien = etat.membres.first(where: { $0.moi }) {
            moi = Membre(id: mien.id, nom: mien.nom, estAdministrateur: mien.administrateur,
                         pseudo: mien.pseudo)
        }
        membres = lus
        autre = lus.first { $0.id != moi.id }

        evenements = etat.evenements.map { lu in
            Evenement(debut: lu.debut, fin: lu.fin, titre: lu.titre, lieu: lu.lieu,
                      categorie: Categorie(rawValue: lu.categorie) ?? .perso,
                      journeeEntiere: lu.journeeEntiere ?? false)
        }
        taches = etat.taches.map { lue in
            Tache(id: lue.id, titre: lue.titre,
                  pourQui: membre(lue.pour, parmi: lus),
                  categorie: Categorie(rawValue: lue.categorie) ?? .menage,
                  faite: lue.faite || enSuspens[lue.id] != nil,
                  reports: lue.reports ?? 0,
                  enRetard: lue.enRetard ?? false,
                  fin: lue.fin,
                  code: lue.code,
                  reportable: lue.actionsPossibles?.contains("reportee") ?? false)
        }
        conflitDuServeur = etat.conflit.map { lu in
            Conflit(id: lu.id, jour: Self.jour(lu.jour),
                    premier: Self.cours(lu.existante), second: Self.cours(lu.nouvelle))
        }
        absences = etat.absences.map { lue in
            Absence(id: lue.id, pour: membre(lue.pour, parmi: lus),
                    debut: lue.debut, fin: lue.fin, lieu: lue.lieu)
        }
        allegements = etat.allegements.map { lu in
            Allegement(pour: membre(lu.pour, parmi: lus), debut: lu.debut, fin: lu.fin)
        }
        propositions = etat.propositions.map { lue in
            Proposition(id: lue.id, debut: lue.debut, fin: lue.fin, lieu: lue.lieu ?? "chez toi")
        }
        var minutes: [Int: Int] = [:]
        for ligne in etat.equilibre { minutes[ligne.pour] = ligne.minutes }
        minutesFaites = minutes
        if let lus = etat.droits {
            droits = Droits(ajouter: lus.ajouter, modifier: lus.modifier)
        }
        orbeADire = etat.orbe
        calendriersSuivis = etat.depart?.calendriers
        tachesDuFoyer = etat.depart?.taches
        chat = EtatChat(litiere: Dates.relatif(etat.chat?.litiere),
                        eau: Dates.relatif(etat.chat?.eau),
                        fontaine: Dates.relatif(etat.chat?.fontaine))
        charge = true
    }

    private static func jour(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
            .locale(Locale(identifier: "fr_FR"))).capitalized
    }

    private static func cours(_ cours: EtatDuJour.CoursAPI) -> Conflit.Cours {
        let debut = cours.debut.formatted(date: .omitted, time: .shortened)
        let fin = cours.fin.formatted(date: .omitted, time: .shortened)
        return Conflit.Cours(titre: cours.titre, horaire: "\(debut) – \(fin)", salle: cours.lieu ?? "")
    }

    // MARK: Ce que les widgets lisent

    var evenementsDuJour: [Evenement] { !connecte && essais.foyerVide ? [] : evenements }
    var tachesDuJour: [Tache] { !connecte && essais.foyerVide ? [] : taches }
    var tachesEnRetard: [Tache] {
        tachesDuJour.filter { ($0.enRetard || $0.reports > 0) && !$0.faite }
    }

    /// 8.6 : aucun calendrier suivi, ni par moi ni pour moi. Aujourd'hui le
    /// rappelle tant que c'est vrai (PRE-3).
    var sansCalendrier: Bool {
        connecte ? calendriersSuivis == 0 : essais.foyerVide
    }

    /// 8.8 : le foyer n'a encore aucune tâche. Maison le dit, avec de quoi en ajouter.
    var sansTache: Bool {
        connecte ? tachesDuFoyer == 0 : essais.foyerVide
    }

    /// DEM-1 : le premier bloc du démarrage de HAL qui manque, ou rien s'il est fini.
    var demarrageDeHAL: String? {
        connecte ? sportDuServeur?.demarrage : (essais.foyerVide ? "profil" : nil)
    }

    /// L'événement en cours ou le prochain.
    var maintenant: Evenement? {
        let date = Date()
        return evenementsDuJour.first { !$0.journeeEntiere && ($0.fin ?? $0.debut) > date }
    }

    var ensuite: Evenement? {
        guard let maintenant, let rang = evenementsDuJour.firstIndex(of: maintenant),
              rang + 1 < evenementsDuJour.count else { return nil }
        return evenementsDuJour[rang + 1]
    }

    var conflit: Conflit? {
        if connecte { return conflitDuServeur }
        return essais.conflit && !essais.foyerVide ? conflitEnCours : nil
    }

    var ajustement: Ajustement? {
        guard connecte else { return essais.ajustement ? ajustementEnCours : nil }
        return sportDuServeur?.ajustements.first.map {
            Ajustement(id: $0.idAjustement, titre: Self.nature($0.nature, $0.typeSeance), motif: $0.motif)
        }
    }

    var mesureDemandee: MesureDemandee? {
        guard connecte else { return essais.mesure ? mesureEnCours : nil }
        return sportDuServeur?.mesures.first(where: \.commencee).map { fenetre in
            MesureDemandee(titre: TypeMesure.nom(fenetre.typeMesure),
                           consigne: fenetre.consigne ?? "Quand tu peux, d'ici la fin de la fenêtre.",
                           jusquA: "jusqu'au " + fenetre.au.formatted(
                               .dateTime.weekday(.abbreviated).day().locale(Locale(identifier: "fr_FR"))),
                           id: fenetre.idFenetre, type: fenetre.typeMesure)
        }
    }

    var seanceAPrevoir: SeanceDuJour? {
        guard connecte else { return essais.jourDeMuscu ? seance : nil }
        return seanceDuJour.map { detail in
            SeanceDuJour(titre: detail.titre,
                         heure: detail.seance.debut?.formatted(date: .omitted, time: .shortened) ?? "",
                         duree: detail.seance.dureeMinutes.map { "\($0 / 60) h \(String(format: "%02d", $0 % 60))" } ?? "",
                         exercices: detail.prevu.map(\.libelle),
                         consigne: detail.seance.consigne ?? "")
        }
    }

    private static func nature(_ nature: String, _ seance: String?) -> String {
        let quoi = seance.map { " · \($0)" } ?? ""
        switch nature {
        case "alleger": return "Alléger la séance" + quoi
        case "deplacer": return "Déplacer la séance" + quoi
        case "retirer": return "Retirer la séance" + quoi
        default: return "Modifier la séance" + quoi
        }
    }

    /// Mon mode allégé en cours, s'il y en a un.
    var monAllegement: Allegement? {
        if connecte { return allegements.first { $0.pour == moi && $0.debut <= .now } }
        return essais.modeAllege
            ? Allegement(pour: moi, debut: .now, fin: .now.addingTimeInterval(2 * 86_400)) : nil
    }

    /// L'absence en cours ou la prochaine de l'autre.
    var absenceDeLAutre: Absence? {
        if connecte { return absences.first { $0.pour != moi } }
        guard essais.absence, let autre else { return nil }
        return Absence(id: 0, pour: autre, debut: .now, fin: .now.addingTimeInterval(86_400), lieu: nil)
    }

    var mesAbsences: [Absence] { absences.filter { $0.pour == moi } }

    /// La part du temps passé aux tâches partagées sur sept jours, de 0 à 1.
    var partDeMoi: Double {
        if connecte {
            let total = minutesFaites.values.reduce(0, +)
            guard total > 0 else { return 0.5 }
            return Double(minutesFaites[moi.id] ?? 0) / Double(total)
        }
        let faites = tachesDuJour.filter(\.faite)
        guard !faites.isEmpty else { return 0.5 }
        return Double(faites.filter { $0.pourQui == moi }.count) / Double(faites.count)
    }

    // MARK: Ce que l'utilisateur fait

    /// Coche une tâche, même celle de l'autre (EXE-14). L'envoi part après cinq
    /// secondes, le temps d'annuler (ORB-6), puis passe par la file d'attente,
    /// qui le garde si le réseau manque (APP-3). Rend de quoi annuler.
    @discardableResult
    func cocher(_ tache: Tache, file: FileAttente) -> (() -> Void)? {
        guard let rang = taches.firstIndex(where: { $0.id == tache.id }), !taches[rang].faite else { return nil }
        taches[rang].faite = true
        let id = tache.id
        enSuspens[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.enSuspens[id] = nil
            if self.connecte { file.ajouter(methode: "POST", chemin: "occurrences/\(id)/valider") }
        }
        return { [weak self] in
            guard let self else { return }
            self.enSuspens[id]?.cancel()
            self.enSuspens[id] = nil
            if let rang = self.taches.firstIndex(where: { $0.id == id }) { self.taches[rang].faite = false }
        }
    }

    /// Repousse une tâche : le moteur lui cherche un autre créneau.
    func reporter(_ tache: Tache, file: FileAttente) {
        taches.removeAll { $0.id == tache.id }
        if connecte { file.ajouter(methode: "POST", chemin: "occurrences/\(tache.id)/reporter") }
    }

    private struct Arbitrage: Encodable { let garder: String }

    /// COL-12 : garde un des deux cours. Le premier est celui déjà au planning.
    func choisir(_ cours: Conflit.Cours) async throws {
        guard let client, let conflit = conflitDuServeur else {
            essais.conflit = false
            return
        }
        let garder = cours == conflit.premier ? "existante" : "nouvelle"
        try await client.envoyer("POST", "conflits/\(conflit.id)/resoudre",
                                 corps: ClientAPI.corps(Arbitrage(garder: garder)))
        conflitDuServeur = nil
        await charger()
    }

    /// Cache le conflit jusqu'au prochain chargement.
    func remettreAPlusTard() {
        if connecte { conflitDuServeur = nil } else { essais.conflit = false }
    }

    /// PLN-18 : accepter ou refuser l'ajustement proposé par HAL.
    func repondreAjustement(accepte: Bool) async throws {
        guard connecte, let premier = sportDuServeur?.ajustements.first else {
            essais.ajustement = false
            return
        }
        try await agir("POST", "ajustements/\(premier.idAjustement)/\(accepte ? "accepter" : "refuser")")
    }

    /// Une action qui demande une réponse du serveur : elle n'attend pas dans la
    /// file, et son refus s'affiche dans le formulaire qui l'a lancée.
    func agir(_ methode: String, _ chemin: String, corps: Data? = nil) async throws {
        guard let client else { return }
        try await client.envoyer(methode, chemin, corps: corps)
        await charger()
    }

    func demander<Reponse: Decodable & Sendable>(_ methode: String, _ chemin: String,
                                      corps: Data? = nil) async throws -> Reponse {
        guard let client else {
            throw ErreurAPI(code: "demonstration", message: "Pas de serveur en démonstration")
        }
        return try await client.requete(methode, chemin, corps: corps)
    }

    // MARK: Le cache

    private static var fichierCache: URL {
        let dossier = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        return dossier.appendingPathComponent("etat-du-jour.json")
    }

    private static func ecrireLeCache(_ etat: EtatDuJour) {
        guard let donnees = try? ClientAPI.encodeur.encode(etat) else { return }
        try? donnees.write(to: fichierCache, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func lireLeCache() -> EtatDuJour? {
        guard let donnees = try? Data(contentsOf: fichierCache) else { return nil }
        return try? ClientAPI.decodeur.decode(EtatDuJour.self, from: donnees)
    }

    static func fichier(_ nom: String) -> URL {
        let dossier = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        return dossier.appendingPathComponent(nom)
    }

    private static func ecrire<Valeur: Encodable>(_ valeur: Valeur, _ nom: String) {
        guard let donnees = try? ClientAPI.encodeur.encode(valeur) else { return }
        try? donnees.write(to: fichier(nom), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func lire<Valeur: Decodable>(_ nom: String) -> Valeur? {
        guard let donnees = try? Data(contentsOf: fichier(nom)) else { return nil }
        return try? ClientAPI.decodeur.decode(Valeur.self, from: donnees)
    }

    private static func effacerLeCache() {
        try? FileManager.default.removeItem(at: fichierCache)
    }
}
