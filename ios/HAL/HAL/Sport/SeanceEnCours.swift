import Foundation
import Observation
import UserNotifications

/// Un exercice de la séance en cours : une ligne prévue par HAL, ou un exercice
/// ajouté dans une séance libre.
/// `GET /exercices/{code}/records` : la charge la plus lourde, et la plus
/// lourde tenue sur au moins dix répétitions (SAI-20).
struct RecordsExercice: Decodable, Sendable {
    struct Serie: Decodable, Sendable {
        let chargeKg: Double
        let repetitions: Int
        let quand: Date
    }
    let max: Serie?
    let max10: Serie?
}

struct ExerciceDeSeance: Codable, Hashable, Identifiable {
    let code: String
    let libelle: String
    let mesure: String
    /// La ligne prévue : la série s'y rattache (SAI-2). Vide pour un ajout.
    let idSeanceExercice: Int?
    let series: Int?
    let repetitionsMin: Int?
    let repetitionsMax: Int?
    let chargeKg: Double?
    let dureeSecondes: Int?
    let reposSecondes: Int?
    let consigne: String?
    let alternatives: [LignePrevue.Alternative]

    var id: String { "\(idSeanceExercice ?? 0)-\(code)" }
    var enDuree: Bool { mesure == "duree" }
    var enDistance: Bool { mesure == "distance" }

    /// Les répétitions visées : le haut de la fourchette.
    var repetitionsVisees: Int? { repetitionsMax ?? repetitionsMin }

    init(_ ligne: LignePrevue) {
        code = ligne.code
        libelle = ligne.libelle
        mesure = ligne.mesure ?? "charge_reps"
        idSeanceExercice = ligne.idSeanceExercice
        series = ligne.series
        repetitionsMin = ligne.repetitionsMin
        repetitionsMax = ligne.repetitionsMax
        chargeKg = ligne.chargeKg
        dureeSecondes = ligne.dureeSecondes
        reposSecondes = ligne.reposSecondes
        consigne = ligne.consigne
        alternatives = ligne.alternatives ?? []
    }

    init(_ exercice: ExerciceCatalogue) {
        code = exercice.code
        libelle = exercice.libelle
        mesure = exercice.mesure ?? "charge_reps"
        idSeanceExercice = nil
        series = nil
        repetitionsMin = nil
        repetitionsMax = nil
        chargeKg = nil
        dureeSecondes = nil
        reposSecondes = nil
        consigne = nil
        alternatives = []
    }
}

/// Une série saisie sur le téléphone. Sa clé, créée ici, la rend unique sur le
/// serveur : la renvoyer après une coupure ne crée rien de plus (SAI-9).
struct SerieLocale: Codable, Hashable, Identifiable {
    let cle: UUID
    /// SAI-22 : une série suit l'exercice qu'on change en cours de séance.
    var code: String
    var libelle: String
    let idSeanceExercice: Int?
    var numero: Int
    let chargeKg: Double?
    let repetitions: Int?
    let dureeSecondes: Int?
    let distanceM: Int?
    /// L'heure où elle a été faite, pas celle où elle arrive (SAI-11).
    let saisieLe: Date
    /// « J'ai bloqué avant » : la série notée telle quelle (SAI-17).
    var bloquee = false
    /// La série intermédiaire ajoutée après une série bloquée (SAI-17).
    var intermediaire = false

    var id: UUID { cle }

    var enClair: String {
        Self.texte(charge: chargeKg, reps: repetitions, duree: dureeSecondes, distance: distanceM)
    }

    /// « 62,5 kg × 6 », « 8 reps », « 45 s ».
    static func texte(charge: Double?, reps: Int?, duree: Int?, distance: Int?) -> String {
        if let duree { return "\(duree) s" }
        if let distance { return "\(distance) m" }
        switch (charge, reps) {
        case let (charge?, reps?): return "\(Poids.texte(charge)) × \(reps)"
        case let (nil, reps?): return "\(reps) reps"
        case let (charge?, nil): return Poids.texte(charge)
        default: return "série"
        }
    }
}

/// Ce que l'écran pré-remplit pour la prochaine série.
struct SerieProposee: Codable, Hashable {
    var chargeKg: Double?
    var repetitions: Int?
    var dureeSecondes: Int?
    var distanceM: Int?
    var intermediaire = false
}

/// La séance gardée sur le téléphone. Elle survit à la fermeture de l'appli et
/// à une coupure de réseau : tout ce qui part au serveur passe par la file.
struct SeanceLocale: Codable {
    /// La clé de la séance libre, donnée par l'appareil (SAI-9).
    let cle: UUID
    /// Le numéro de la séance prévue. Vide pour une séance libre ouverte ici.
    let idOccurrence: Int?
    let libre: Bool
    let titre: String
    let debut: Date
    var exercices: [ExerciceDeSeance]
    var series: [SerieLocale]
    var courant: Int
    var proposition: SerieProposee?
    var consigne: String?
    /// Les séries déjà sur le serveur au lancement : annuler ne les retire pas (SAI-19).
    var dejaSaisies: Int? = nil
}

/// La séance de musculation en cours (3.5 à 3.9). Une seule à la fois.
@MainActor
@Observable
final class SeanceEnCours {
    private(set) var seance: SeanceLocale?
    /// Montrer l'écran de la séance par-dessus tout le reste.
    var affichee = false
    /// La fin du repos en cours, s'il y en a un (SAI-18).
    private(set) var finDuRepos: Date?
    private(set) var dureeDuRepos: TimeInterval = 90
    private var debutDuRepos: Date?
    private let activite = ActiviteEnDirect()

    init() {
        seance = Self.lire()
        PontSeance.passerLeRepos = { [weak self] in self?.passerLeRepos() }
        publierLActivite()
    }

    /// IOS-3 : l'exercice, la série et le repos, sur l'écran verrouillé et dans la
    /// Dynamic Island.
    private func publierLActivite() {
        guard let seance else {
            activite.terminer()
            PourLesWidgets.publier(seance: nil)
            return
        }
        let exercice = exerciceCourant
        let etat = AttributsSeance.ContentState(
            exercice: exercice?.libelle ?? "Choisis un exercice",
            serie: (exercice.map { series(de: $0).filter { !$0.intermediaire }.count } ?? 0) + 1,
            seriesPrevues: exercice?.series,
            seriesFaites: seance.series.count,
            debutDuRepos: finDuRepos == nil ? nil : debutDuRepos,
            finDuRepos: finDuRepos)
        activite.publier(titre: seance.titre, debut: seance.debut, etat: etat)
        PourLesWidgets.publier(seance: SeanceEnWidget(titre: seance.titre, debut: seance.debut, etat: etat))
    }

    var enCours: Bool { seance != nil }

    var exerciceCourant: ExerciceDeSeance? {
        guard let seance, seance.exercices.indices.contains(seance.courant) else { return nil }
        return seance.exercices[seance.courant]
    }

    func series(de exercice: ExerciceDeSeance) -> [SerieLocale] {
        seance?.series.filter { $0.code == exercice.code && $0.idSeanceExercice == exercice.idSeanceExercice } ?? []
    }

    /// Le chemin des séries : par numéro si le serveur le connaît, par la clé sinon.
    private var racine: String {
        guard let seance else { return "" }
        if let id = seance.idOccurrence { return "seances/\(id)" }
        return "seances/par-cle/\(seance.cle.uuidString)"
    }

    // MARK: Lancer

    /// Lance la séance prévue par HAL, avec ce qui est déjà saisi (3.3).
    func lancer(_ detail: DetailSeance) {
        if let seance, seance.idOccurrence == detail.seance.idOccurrence {
            affichee = true
            return
        }
        let deja = detail.saisi.map { serie in
            SerieLocale(cle: UUID(), code: serie.code, libelle: serie.libelle ?? serie.code,
                        idSeanceExercice: serie.idSeanceExercice, numero: serie.numero ?? 1,
                        chargeKg: serie.chargeKg, repetitions: serie.repetitions,
                        dureeSecondes: serie.dureeSecondes, distanceM: serie.distanceM,
                        saisieLe: serie.saisieLe ?? .now)
        }
        seance = SeanceLocale(cle: UUID(), idOccurrence: detail.seance.idOccurrence,
                              libre: detail.seance.libre ?? false, titre: detail.titre, debut: .now,
                              exercices: detail.prevu.map(ExerciceDeSeance.init), series: deja,
                              courant: 0, proposition: nil, consigne: detail.seance.consigne,
                              dejaSaisies: deja.count)
        enregistrer()
        affichee = true
        demanderLesNotifications()
    }

    private struct OuvertureLibre: Encodable {
        let discipline: String
        let cleClient: UUID
        let debut: Date
    }

    /// Une séance qui n'était pas prévue (SAI-6). Elle s'ouvre sur le serveur
    /// par la file : sans réseau, elle partira au retour.
    func lancerLibre(file: FileAttente) {
        if seance != nil {
            affichee = true
            return
        }
        let cle = UUID()
        let debut = Date.now
        seance = SeanceLocale(cle: cle, idOccurrence: nil, libre: true, titre: "Séance libre",
                              debut: debut, exercices: [], series: [], courant: 0,
                              proposition: nil, consigne: nil)
        file.ajouter(methode: "POST", chemin: "seances/libre",
                     corps: ClientAPI.corps(OuvertureLibre(discipline: "musculation", cleClient: cle,
                                                           debut: debut)))
        enregistrer()
        affichee = true
        demanderLesNotifications()
    }

    /// LIB-2 : un exercice ajouté à la séance.
    func ajouter(_ exercice: ExerciceCatalogue) {
        guard var seance else { return }
        seance.exercices.append(ExerciceDeSeance(exercice))
        seance.courant = seance.exercices.count - 1
        seance.proposition = nil
        self.seance = seance
        enregistrer()
    }

    /// SAI-3 : une alternative du catalogue prend la place de l'exercice prévu.
    /// La ligne prévue garde ses séries et ses répétitions. SAI-22 : les séries
    /// déjà faites suivent.
    func remplacer(par alternative: LignePrevue.Alternative, file: FileAttente) {
        guard let actuel = exerciceCourant else { return }
        changer(actuel, pour: ExerciceDeSeance(remplacant: alternative, de: actuel), file: file)
    }

    /// SAI-22 : un exercice du catalogue à la place de celui-ci, qu'on s'est trompé
    /// ou qu'on change de machine. Rend le motif d'un refus : un exercice qui ne se
    /// note pas pareil ne peut pas reprendre des séries déjà faites.
    @discardableResult
    func changer(pour exercice: ExerciceCatalogue, file: FileAttente) -> String? {
        guard let actuel = exerciceCourant else { return nil }
        let mesure = exercice.mesure ?? "charge_reps"
        if mesure != actuel.mesure, !series(de: actuel).isEmpty {
            return "\(exercice.libelle) ne se note pas comme \(actuel.libelle) : tes séries ne peuvent pas le suivre. Retire cet exercice, puis ajoute l'autre."
        }
        changer(actuel, pour: ExerciceDeSeance(remplacant: exercice, de: actuel), file: file)
        return nil
    }

    private struct Deplacement: Encodable {
        let cles: [UUID]
        let code: String
    }

    /// Le nouvel exercice prend la place ; ses séries déjà faites sont celles de
    /// l'ancien, renumérotées à la suite, ici et sur le serveur.
    private func changer(_ actuel: ExerciceDeSeance, pour remplacant: ExerciceDeSeance, file: FileAttente) {
        guard var seance else { return }
        let deplacees = series(de: actuel).map(\.cle)
        var numero = seance.series.filter { $0.code == remplacant.code && !deplacees.contains($0.cle) }.count
        for rang in seance.series.indices where deplacees.contains(seance.series[rang].cle) {
            numero += 1
            seance.series[rang].code = remplacant.code
            seance.series[rang].libelle = remplacant.libelle
            seance.series[rang].numero = numero
        }
        seance.exercices[seance.courant] = remplacant
        self.seance = seance
        if !deplacees.isEmpty {
            file.ajouter(methode: "POST", chemin: "\(racine)/series/changer-exercice",
                         corps: ClientAPI.corps(Deplacement(cles: deplacees, code: remplacant.code)))
        }
        enregistrer()
    }

    // MARK: Corriger                                                    (SAI-22)

    private struct Annulees: Encodable { let cles: [UUID] }

    /// Retire des séries, ici et sur le serveur. Celles déjà là au lancement
    /// sortent aussi du compte de ce qui préexistait (SAI-19).
    private func retirer(_ cles: [UUID], file: FileAttente) {
        guard var seance, !cles.isEmpty else { return }
        let avant = seance.series.prefix(seance.dejaSaisies ?? 0).filter { cles.contains($0.cle) }.count
        seance.series.removeAll { cles.contains($0.cle) }
        if let deja = seance.dejaSaisies { seance.dejaSaisies = deja - avant }
        self.seance = seance
        file.ajouter(methode: "POST", chemin: "\(racine)/annuler-saisie",
                     corps: ClientAPI.corps(Annulees(cles: cles)))
    }

    /// « Annuler la dernière série » : notée par erreur, elle s'en va, et le
    /// repos qu'elle avait lancé aussi. Après une série bloquée, la série
    /// intermédiaire proposée part avec elle.
    func annulerDerniereSerie(file: FileAttente) {
        guard let exercice = exerciceCourant, let derniere = series(de: exercice).last else { return }
        supprimer(derniere, file: file)
    }

    /// Une série de la liste, touchée longuement : « Supprimer cette série ».
    func supprimer(_ serie: SerieLocale, file: FileAttente) {
        let derniere = seance?.series.last?.cle == serie.cle
        retirer([serie.cle], file: file)
        if derniere {
            passerLeRepos()
            if serie.bloquee, seance?.proposition?.intermediaire == true { seance?.proposition = nil }
        }
        enregistrer()
    }

    /// « Retirer cet exercice » : lancé par erreur, il quitte la séance avec ses
    /// séries. Prévu par HAL, sa ligne reste sur le serveur, sans série : HAL
    /// le lira comme pas fait.
    func retirerExercice(file: FileAttente) {
        guard let exercice = exerciceCourant else { return }
        retirer(series(de: exercice).map(\.cle), file: file)
        guard var seance else { return }
        seance.exercices.remove(at: seance.courant)
        seance.courant = min(seance.courant, max(0, seance.exercices.count - 1))
        seance.proposition = nil
        self.seance = seance
        passerLeRepos()
        enregistrer()
    }

    /// « Passer à l'exercice suivant », sans finir celui-ci : ses séries restent.
    var aUnSuivant: Bool {
        guard let seance else { return false }
        return seance.courant + 1 < seance.exercices.count
    }

    func passerExercice() {
        guard let seance, aUnSuivant else { return }
        aller(a: seance.courant + 1)
    }

    func aller(a rang: Int) {
        guard var seance, seance.exercices.indices.contains(rang) else { return }
        seance.courant = rang
        seance.proposition = nil
        self.seance = seance
        enregistrer()
    }

    // MARK: Les séries

    /// Ce qui se pré-remplit : la série intermédiaire si elle est due, sinon le
    /// poids de la dernière série normale, sinon ce que HAL a prévu.
    func proposee(pour exercice: ExerciceDeSeance) -> SerieProposee {
        if let proposition = seance?.proposition { return proposition }
        let faites = series(de: exercice)
        let reference = faites.last { !$0.intermediaire && !$0.bloquee } ?? faites.last
        return SerieProposee(chargeKg: reference?.chargeKg ?? exercice.chargeKg,
                             repetitions: exercice.repetitionsVisees ?? reference?.repetitions ?? 10,
                             dureeSecondes: exercice.dureeSecondes ?? reference?.dureeSecondes,
                             distanceM: reference?.distanceM)
    }

    private struct SerieEnvoyee: Encodable {
        let code: String
        let cleClient: UUID
        let numero: Int
        let chargeKg: Double?
        let repetitions: Int?
        let dureeSecondes: Int?
        let distanceM: Int?
        let saisieLe: Date
        let idSeanceExercice: Int?
    }

    @discardableResult
    private func noter(_ exercice: ExerciceDeSeance, charge: Double?, reps: Int?, duree: Int?,
                       distance: Int?, bloquee: Bool, intermediaire: Bool,
                       file: FileAttente) -> SerieLocale? {
        guard var seance else { return nil }
        let numero = seance.series.filter { $0.code == exercice.code }.count + 1
        var serie = SerieLocale(cle: UUID(), code: exercice.code, libelle: exercice.libelle,
                                idSeanceExercice: exercice.idSeanceExercice, numero: numero,
                                chargeKg: exercice.enDuree || exercice.enDistance ? nil : charge,
                                repetitions: exercice.enDuree || exercice.enDistance ? nil : reps,
                                dureeSecondes: exercice.enDuree ? duree : nil,
                                distanceM: exercice.enDistance ? distance : nil,
                                saisieLe: .now)
        serie.bloquee = bloquee
        serie.intermediaire = intermediaire
        seance.series.append(serie)
        self.seance = seance
        let envoi = SerieEnvoyee(code: serie.code, cleClient: serie.cle, numero: serie.numero,
                                 chargeKg: serie.chargeKg, repetitions: serie.repetitions,
                                 dureeSecondes: serie.dureeSecondes, distanceM: serie.distanceM,
                                 saisieLe: serie.saisieLe, idSeanceExercice: serie.idSeanceExercice)
        file.ajouter(methode: "POST", chemin: "\(racine)/series", corps: ClientAPI.corps([envoi]))
        return serie
    }

    /// SAI-1 : la série faite comme prévu. Le repos part tout de suite (SAI-18).
    func valider(charge: Double?, reps: Int?, duree: Int?, distance: Int?, file: FileAttente) {
        guard let exercice = exerciceCourant else { return }
        let intermediaire = seance?.proposition?.intermediaire ?? false
        noter(exercice, charge: charge, reps: reps, duree: duree, distance: distance,
              bloquee: false, intermediaire: intermediaire, file: file)
        seance?.proposition = nil
        avancerSiFini(exercice)
        enregistrer()
        lancerLeRepos(exercice)
    }

    /// SAI-17 : « J'ai bloqué avant ». La série est notée telle quelle, puis une
    /// série intermédiaire est proposée : les répétitions prévues, le poids baissé
    /// de 10 % s'il manquait une ou deux répétitions, de 20 % au-delà, arrondi au
    /// palier de 2,5 kg. Une règle fixe, sur le téléphone, sans HAL ni réseau.
    func bloque(charge: Double?, repsFaites: Int, repsVisees: Int, file: FileAttente) {
        guard let exercice = exerciceCourant else { return }
        noter(exercice, charge: charge, reps: repsFaites, duree: nil, distance: nil,
              bloquee: true, intermediaire: false, file: file)
        let manque = max(0, repsVisees - repsFaites)
        let facteur = manque <= 2 ? 0.9 : 0.8
        seance?.proposition = SerieProposee(chargeKg: charge.map { Poids.palier($0 * facteur) },
                                            repetitions: repsVisees, intermediaire: true)
        enregistrer()
        lancerLeRepos(exercice)
    }

    /// Passe à l'exercice suivant quand toutes les séries prévues sont faites.
    private func avancerSiFini(_ exercice: ExerciceDeSeance) {
        guard var seance, let prevues = exercice.series,
              series(de: exercice).filter({ !$0.intermediaire }).count >= prevues,
              seance.courant + 1 < seance.exercices.count else { return }
        seance.courant += 1
        self.seance = seance
    }

    // MARK: Le repos

    private func lancerLeRepos(_ exercice: ExerciceDeSeance) {
        dureeDuRepos = TimeInterval(exercice.reposSecondes ?? 90)
        debutDuRepos = .now
        finDuRepos = Date.now.addingTimeInterval(dureeDuRepos)
        publierLActivite()
        // Téléphone posé ou verrouillé : une notification sonne à la fin, et la
        // Live Activity montre le compte à rebours (IOS-3).
        let contenu = UNMutableNotificationContent()
        contenu.title = "Repos terminé"
        contenu.body = "À toi : \(exercice.libelle)"
        contenu.sound = .default
        let centre = UNUserNotificationCenter.current()
        centre.removePendingNotificationRequests(withIdentifiers: ["repos"])
        centre.add(UNNotificationRequest(
            identifier: "repos", content: contenu,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: dureeDuRepos, repeats: false)))
    }

    /// 3.7 : « −15 s » et « +30 s » sur le repos en cours.
    func ajusterLeRepos(_ secondes: TimeInterval) {
        guard let fin = finDuRepos else { return }
        let nouvelle = fin.addingTimeInterval(secondes)
        guard nouvelle > .now else { passerLeRepos(); return }
        finDuRepos = nouvelle
        dureeDuRepos = max(1, dureeDuRepos + secondes)
        let centre = UNUserNotificationCenter.current()
        centre.removePendingNotificationRequests(withIdentifiers: ["repos"])
        if let exercice = exerciceCourant {
            let contenu = UNMutableNotificationContent()
            contenu.title = "Repos terminé"
            contenu.body = "À toi : \(exercice.libelle)"
            contenu.sound = .default
            centre.add(UNNotificationRequest(
                identifier: "repos", content: contenu,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: nouvelle.timeIntervalSinceNow, repeats: false)))
        }
        publierLActivite()
    }

    /// 3.6 : « Annuler » la série intermédiaire proposée ; on reprend la suite prévue.
    func renoncerALIntermediaire() {
        guard seance?.proposition?.intermediaire == true else { return }
        seance?.proposition = nil
        enregistrer()
    }

    func passerLeRepos() {
        finDuRepos = nil
        debutDuRepos = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["repos"])
        publierLActivite()
    }

    private func demanderLesNotifications() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    // MARK: Terminer                                                   (SAI-15)

    private struct BilanEnvoye: Encodable {
        let effort: Int
        let dureeMinutes: Int
        let commentaire: String?
        let cleClient: UUID
    }

    /// SAI-4 : la note d'effort, la durée réelle, le commentaire. Le bilan part
    /// par la file : l'avis de HAL arrive ensuite dans son panneau (SAI-7).
    func bilan(effort: Int, minutes: Int, commentaire: String, avisDeHAL: Bool, file: FileAttente) {
        guard seance != nil else { return }
        let texte = commentaire.trimmingCharacters(in: .whitespacesAndNewlines)
        file.ajouter(methode: "POST", chemin: "\(racine)/bilan?appeler_coach=\(avisDeHAL)",
                     corps: ClientAPI.corps(BilanEnvoye(effort: effort, dureeMinutes: max(1, minutes),
                                                         commentaire: texte.isEmpty ? nil : texte,
                                                         cleClient: UUID())))
        oublier()
    }

    /// Pas faite : la séance prévue est close comme telle, HAL décide de la suite (PLN-10).
    func pasFaite(file: FileAttente) {
        if let id = seance?.idOccurrence {
            file.ajouter(methode: "POST", chemin: "seances/\(id)/pas-faite")
        }
        oublier()
    }

    /// SAI-19 : une séance lancée par erreur. Libre, elle disparaît avec ses
    /// séries ; prévue, elle reste à faire, sans les séries de ce lancement.
    /// Tout passe par la file : sans réseau, l'annulation part au retour.
    func annuler(file: FileAttente) {
        guard let seance else { return }
        if let id = seance.idOccurrence {
            let cles = seance.series.dropFirst(seance.dejaSaisies ?? 0).map(\.cle)
            if !cles.isEmpty {
                file.ajouter(methode: "POST", chemin: "seances/\(id)/annuler-saisie",
                             corps: ClientAPI.corps(Annulees(cles: Array(cles))))
            }
        } else {
            file.ajouter(methode: "DELETE", chemin: "seances/par-cle/\(seance.cle.uuidString)")
        }
        oublier()
    }

    /// SAI-16 : « Déjà faite, sans saisie », sans ouvrir la séance.
    static func dejaFaite(_ detail: DetailSeance, file: FileAttente) {
        file.ajouter(methode: "POST", chemin: "occurrences/\(detail.seance.idOccurrence)/valider")
    }

    /// Oublie la séance sur le téléphone. Ce qui est parti reste sur le serveur.
    func oublier() {
        passerLeRepos()
        Yanga.oublierLaNotification()
        seance = nil
        affichee = false
        enregistrer()
    }

    var minutesEcoulees: Int {
        guard let seance else { return 0 }
        return max(1, Int(Date.now.timeIntervalSince(seance.debut) / 60))
    }

    // MARK: Sur le téléphone

    private static var fichier: URL {
        let dossier = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        return dossier.appendingPathComponent("seance-en-cours.json")
    }

    private func enregistrer() {
        defer { publierLActivite() }
        guard let seance else {
            try? FileManager.default.removeItem(at: Self.fichier)
            return
        }
        guard let donnees = try? JSONEncoder().encode(seance) else { return }
        try? donnees.write(to: Self.fichier, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func lire() -> SeanceLocale? {
        guard let donnees = try? Data(contentsOf: fichier) else { return nil }
        return try? JSONDecoder().decode(SeanceLocale.self, from: donnees)
    }
}

extension ExerciceDeSeance {
    /// SAI-22 : un exercice du catalogue à la place, avec la ligne prévue de
    /// l'ancien. La charge prévue ne vaut plus : un autre exercice, un autre poids.
    init(remplacant exercice: ExerciceCatalogue, de ligne: ExerciceDeSeance) {
        code = exercice.code
        libelle = exercice.libelle
        mesure = exercice.mesure ?? ligne.mesure
        idSeanceExercice = ligne.idSeanceExercice
        series = ligne.series
        repetitionsMin = ligne.repetitionsMin
        repetitionsMax = ligne.repetitionsMax
        chargeKg = nil
        dureeSecondes = ligne.dureeSecondes
        reposSecondes = ligne.reposSecondes
        consigne = ligne.consigne
        alternatives = ligne.alternatives.filter { $0.code != exercice.code }
    }

    /// L'alternative garde la ligne prévue : ses séries, ses répétitions, son repos.
    init(remplacant alternative: LignePrevue.Alternative, de ligne: ExerciceDeSeance) {
        code = alternative.code
        libelle = alternative.libelle
        mesure = ligne.mesure
        idSeanceExercice = ligne.idSeanceExercice
        series = ligne.series
        repetitionsMin = ligne.repetitionsMin
        repetitionsMax = ligne.repetitionsMax
        chargeKg = nil
        dureeSecondes = ligne.dureeSecondes
        reposSecondes = ligne.reposSecondes
        consigne = ligne.consigne
        alternatives = ligne.alternatives.filter { $0.code != alternative.code }
    }
}
