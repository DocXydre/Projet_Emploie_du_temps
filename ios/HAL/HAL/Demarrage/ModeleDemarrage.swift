import Foundation
import Observation

/// Les écrans du démarrage (7.1 à 7.17), dans l'ordre.
enum PageDemarrage: String, CaseIterable, Sendable {
    case bienvenue, identite, niveaux, disponibilites, alimentation
    case limitationQuestion, limitationDetail, limitationExercices, limitationAutre
    case lieux, objectif, course, recap, construction, plan, fini

    /// Le bloc auquel l'écran appartient, de 1 à 5, pour la barre d'avancée.
    var etape: Int? {
        switch self {
        case .bienvenue, .fini: nil
        case .identite, .niveaux, .disponibilites, .alimentation: 1
        case .limitationQuestion, .limitationDetail, .limitationExercices, .limitationAutre: 2
        case .lieux: 3
        case .objectif, .course: 4
        case .recap, .construction, .plan: 5
        }
    }

    static let duProfil: [PageDemarrage] = [.identite, .niveaux, .disponibilites, .alimentation]
}

/// Le démarrage de HAL, écran par écran (DEM-1 à DEM-6). Les réponses en cours
/// sont gardées sur le serveur (DEM-2) ; chaque bloc fini passe par sa route
/// habituelle, et un refus de la base est montré tel quel, la question reposée.
@MainActor
@Observable
final class ModeleDemarrage {
    private(set) var page: PageDemarrage = .bienvenue
    private var historique: [PageDemarrage] = []
    private(set) var etat: EtatDemarrage?
    private(set) var charge = false
    private(set) var envoi = false
    var erreur: String?

    // Profil (7.2 à 7.5)
    var naissance = Calendar.current.date(byAdding: .year, value: -25, to: .now) ?? .now
    var sexe: String?
    var taille: Double = 175
    var niveauMusculation: String?
    var niveauCourse: String?
    var moment = "indifferent"
    var joursSansSport: Set<Int> = []
    var maximum: Int?
    var complements: Bool?
    var regime = ""

    // Limitation (7.6 à 7.8)
    var zone: String?
    var cote: String?
    var description = ""
    var interdits: Set<String> = []
    private(set) var limitationEnCours: Int?
    private(set) var catalogue: [ExerciceCatalogue] = []

    // Lieux (7.9)
    var lieux: [String: [Int]] = [:]

    // Objectif (7.10 à 7.12)
    var objectif: String?
    var distance: Int?
    var autreDistance = ""
    var tempsVise = ""
    var justeFinir = false
    var dateCourse = Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now

    /// Ce qu'on veut dire à HAL en plus, écran par écran : gardé et lu par HAL (DEM-1).
    var notes: [String: String] = [:]

    // La fin (7.14 à 7.16)
    private(set) var avis: String?
    private(set) var plan: PlanHAL?
    private(set) var attendLePlan = false

    var client: ClientAPI?

    // MARK: Charger et reprendre

    /// DEM-4 : reprendre là où on s'était arrêté. Ce qui est déjà rempli est sauté.
    func charger() async {
        guard let client else {
            charge = true
            return
        }
        do {
            let lu: EtatDemarrage = try await client.requete("GET", "appli/demarrage")
            etat = lu
            remplir(lu)
            page = premierePage(lu)
            charge = true
        } catch {
            erreur = Self.motif(error)
            charge = true
        }
    }

    private func remplir(_ lu: EtatDemarrage) {
        let b = lu.brouillon
        if let profil = lu.profil {
            naissance = profil.dateNaissance
            sexe = profil.sexe
            taille = Double(profil.tailleCm)
            niveauMusculation = profil.niveauMusculation
            niveauCourse = profil.niveauCourse
            moment = profil.momentPrefere ?? "indifferent"
            joursSansSport = Set(profil.joursSansSport ?? [])
            complements = profil.accordComplements
            regime = profil.regime ?? ""
        } else {
            if let jour = b["naissance"].flatMap(Dates.lire) { naissance = jour }
            sexe = b["sexe"] ?? sexe
            taille = b["taille"].flatMap(Double.init) ?? taille
            niveauMusculation = b["niveau_musculation"] ?? niveauMusculation
            niveauCourse = b["niveau_course"] ?? niveauCourse
            moment = b["moment"] ?? moment
            if let jours = b["jours"] {
                joursSansSport = Set(jours.split(separator: ",").compactMap { Int($0) })
            }
            complements = b["complements"].map { $0 == "1" }
            regime = b["regime"] ?? regime
        }
        maximum = lu.seancesMaxSemaine ?? b["maximum"].flatMap(Int.init)
        zone = b["zone"]
        cote = b["cote"]
        description = b["description"] ?? ""
        for discipline in LibellesHAL.disciplines.map(\.0) {
            let choisis = lu.lieux.filter { $0.discipline == discipline }.sorted { $0.rang < $1.rang }.map(\.idLieu)
            if !choisis.isEmpty { lieux[discipline] = choisis }
        }
        objectif = b["objectif"]
        distance = b["distance"].flatMap(Int.init)
        tempsVise = b["temps"] ?? ""
        justeFinir = b["juste_finir"] == "1"
        if let jour = b["date_course"].flatMap(Dates.lire) { dateCourse = jour }
        for (cle, valeur) in b where cle.hasPrefix("note_") { notes[String(cle.dropFirst(5))] = valeur }
    }

    private func premierePage(_ lu: EtatDemarrage) -> PageDemarrage {
        let gardee = lu.etape.flatMap(PageDemarrage.init(rawValue:))
        switch lu.manque {
        case "profil":
            if let gardee, PageDemarrage.duProfil.contains(gardee) { return gardee }
            return .bienvenue
        case "limitations": return .limitationQuestion
        case "lieux": return .lieux
        case "objectif":
            return gardee == .course ? .course : .objectif
        default:
            return .recap
        }
    }

    var principal: ObjectifDetaille? {
        etat?.objectifs.first { $0.principal && $0.statut == "actif" }
    }

    // MARK: Aller d'écran en écran

    var peutRevenir: Bool { !historique.isEmpty && page != .construction && page != .fini }

    func aller(_ suivante: PageDemarrage) {
        erreur = nil
        historique.append(page)
        page = suivante
        Task { await garderLeBrouillon() }
    }

    func revenir() {
        erreur = nil
        guard let precedente = historique.popLast() else { return }
        page = precedente
    }

    /// Le bouton du bas de chaque écran : il enregistre le bloc s'il est fini.
    func suivant() async {
        erreur = nil
        switch page {
        case .bienvenue: aller(.identite)
        case .identite: aller(.niveaux)
        case .niveaux: aller(.disponibilites)
        case .disponibilites: aller(.alimentation)
        case .alimentation:
            if await enregistrerLeProfil() {
                aller(etat?.limitationsFaites == true ? .lieux : .limitationQuestion)
            }
        case .limitationDetail:
            if await declarerLaLimitation() { await chargerLeCatalogue(); aller(.limitationExercices) }
        case .limitationExercices:
            if await enregistrerLesInterdits() { aller(.limitationAutre) }
        case .lieux:
            if await enregistrerLesLieux() { aller(.objectif) }
        case .objectif:
            aller(objectif == "course" ? .course : .recap)
        case .course: aller(.recap)
        case .recap: await construire()
        case .construction, .plan: aller(.fini)
        case .limitationQuestion, .limitationAutre, .fini: break
        }
    }

    /// 7.6 et 7.8 : « Non » finit le bloc des limitations, « Oui » en décrit une.
    func repondreLimitation(_ oui: Bool) async {
        if oui {
            zone = nil
            cote = nil
            description = ""
            interdits = []
            limitationEnCours = nil
            aller(.limitationDetail)
            return
        }
        guard let client else { aller(.lieux); return }
        envoi = true
        defer { envoi = false }
        do {
            try await client.envoyer("POST", "appli/demarrage/limitations-faites")
            aller(.lieux)
        } catch {
            erreur = Self.motif(error)
        }
    }

    // MARK: Ce qui part au serveur

    private struct Brouillon: Encodable {
        let etape: String
        let reponses: [String: String]
    }

    private var reponses: [String: String] {
        var r: [String: String] = [
            "naissance": TexteHAL.jourISO(naissance), "taille": String(Int(taille)), "moment": moment,
            "jours": joursSansSport.sorted().map(String.init).joined(separator: ","),
            "regime": regime, "description": description, "temps": tempsVise,
            "juste_finir": justeFinir ? "1" : "0", "date_course": TexteHAL.jourISO(dateCourse),
        ]
        r["sexe"] = sexe
        r["niveau_musculation"] = niveauMusculation
        r["niveau_course"] = niveauCourse
        r["maximum"] = maximum.map(String.init)
        r["complements"] = complements.map { $0 ? "1" : "0" }
        r["zone"] = zone
        r["cote"] = cote
        r["objectif"] = objectif
        r["distance"] = distance.map(String.init)
        for (cle, valeur) in notes where !valeur.isEmpty { r["note_\(cle)"] = valeur }
        return r
    }

    /// DEM-2 : les réponses en cours, gardées en base sans rien créer.
    func garderLeBrouillon() async {
        guard let client else { return }
        try? await client.envoyer("PUT", "appli/demarrage/brouillon",
                                  corps: ClientAPI.corps(Brouillon(etape: page.rawValue, reponses: reponses)))
    }

    var profilComplet: Bool {
        sexe != nil && niveauMusculation != nil && niveauCourse != nil && complements != nil
    }

    private func enregistrerLeProfil() async -> Bool {
        guard profilComplet else {
            erreur = "Il manque une réponse plus haut."
            return false
        }
        guard let client else { return true }
        envoi = true
        defer { envoi = false }
        let profil = EnvoiProfil(
            dateNaissance: TexteHAL.jourISO(naissance), sexe: sexe ?? "homme", tailleCm: Int(taille),
            niveauMusculation: niveauMusculation ?? "debutant", niveauCourse: niveauCourse ?? "debutant",
            momentPrefere: moment, joursSansSport: joursSansSport.sorted(),
            accordComplements: complements ?? false,
            regime: regime.trimmingCharacters(in: .whitespaces).isEmpty ? nil : regime)
        do {
            try await client.envoyer("PUT", "profil", corps: ClientAPI.corps(profil))
            struct Maximum: Encodable { let valeur: Int? }
            try await client.envoyer("PUT", "appli/seances-max", corps: ClientAPI.corps(Maximum(valeur: maximum)))
            if etat?.coachActif != true {
                // COA-1 : HAL s'active pour soi. La base refuse une personne mineure (PRO-7).
                try await client.envoyer("POST", "appli/demarrage/activer")
            }
            await rafraichir()
            return true
        } catch {
            erreur = Self.motif(error)
            // Le plus souvent la date de naissance : la question est reposée.
            if (error as? ErreurAPI)?.message.lowercased().contains("naissance") == true
                || (error as? ErreurAPI)?.message.contains("18") == true {
                historique.removeAll { PageDemarrage.duProfil.contains($0) }
                page = .identite
            }
            return false
        }
    }

    private struct NouvelleLimitation: Encodable {
        let libelle: String
        let zone: String
        let cote: String
        let description: String
    }

    private struct Cree: Decodable, Sendable { let idLimitation: Int }

    private func declarerLaLimitation() async -> Bool {
        guard let zone, let cote, description.trimmingCharacters(in: .whitespaces).count >= 5 else {
            erreur = "Dis où, de quel côté, et décris-la en une phrase."
            return false
        }
        guard let client else { limitationEnCours = 0; return true }
        envoi = true
        defer { envoi = false }
        let nomCote = cote == "deux" ? "des deux côtés" : cote
        let nomZone = LibellesHAL.nom(zone, dans: LibellesHAL.zones)
        do {
            let cree: Cree = try await client.requete(
                "POST", "limitations",
                corps: ClientAPI.corps(NouvelleLimitation(libelle: "\(nomZone) (\(nomCote))", zone: zone,
                                                          cote: cote, description: description)))
            limitationEnCours = cree.idLimitation
            interdits = []
            return true
        } catch {
            erreur = Self.motif(error)
            return false
        }
    }

    func chargerLeCatalogue() async {
        guard let client, catalogue.isEmpty else { return }
        catalogue = (try? await client.requete("GET", "exercices?discipline=musculation")) ?? []
    }

    private struct Interdit: Encodable {
        let code: String
        let motif: String
    }

    /// EXO-8 : c'est toi qui dis ce qu'une limitation interdit. Aucun : on passe.
    private func enregistrerLesInterdits() async -> Bool {
        guard let client, let id = limitationEnCours, id > 0, !interdits.isEmpty else { return true }
        envoi = true
        defer { envoi = false }
        let motif = String(description.prefix(200))
        do {
            try await client.envoyer("PUT", "limitations/\(id)/interdits",
                                     corps: ClientAPI.corps(interdits.sorted().map { Interdit(code: $0, motif: motif) }))
            return true
        } catch {
            erreur = Self.motif(error)
            return false
        }
    }

    /// LIE-4 : un lieu touché s'ajoute à la fin, touché encore il s'enlève.
    func basculer(_ lieu: Int, pour discipline: String) {
        var choisis = lieux[discipline] ?? []
        if let rang = choisis.firstIndex(of: lieu) { choisis.remove(at: rang) } else { choisis.append(lieu) }
        lieux[discipline] = choisis
    }

    private func enregistrerLesLieux() async -> Bool {
        guard lieux.values.contains(where: { !$0.isEmpty }) else {
            // LIE-6 : sans lieu, HAL ne peut rien placer.
            erreur = "Il faut au moins un lieu, pour une discipline au moins."
            return false
        }
        guard let client else { return true }
        envoi = true
        defer { envoi = false }
        do {
            for discipline in LibellesHAL.disciplines.map(\.0) {
                try await client.envoyer("PUT", "disciplines/\(discipline)/lieux",
                                         corps: ClientAPI.corps(lieux[discipline] ?? []))
            }
            await rafraichir()
            return true
        } catch {
            erreur = Self.motif(error)
            return false
        }
    }

    private func rafraichir() async {
        guard let client else { return }
        if let lu: EtatDemarrage = try? await client.requete("GET", "appli/demarrage") { etat = lu }
    }

    // MARK: L'objectif et le plan (7.13 à 7.16)

    var distanceChoisie: Int? {
        if let distance { return distance }
        let km = Double(autreDistance.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "km", with: "").trimmingCharacters(in: .whitespaces))
        return km.map { Int($0 * 1000) }
    }

    var objectifEnClair: String {
        if let principal, objectif == nil { return principal.libelle }
        switch objectif {
        case "course":
            let km = (distanceChoisie.map { Double($0) / 1000 } ?? 0).formatted(.number.precision(.fractionLength(0...1)))
            let temps = justeFinir ? "la finir" : LibellesHAL.minutes(tempsVise).map { "en \(LibellesHAL.duree($0))" } ?? ""
            return "\(km) km \(temps), le \(dateCourse.formatted(date: .abbreviated, time: .omitted))"
        case let pilier?: return LibellesHAL.objectifs.first { $0.0 == pilier }?.1 ?? pilier
        case nil: return "à choisir"
        }
    }

    private struct NouvelObjectif: Encodable {
        let type: String
        let libelle: String
        let pilier: String?
        let distanceM: Int?
        let cibleValeur: Double?
        let cibleUnite: String?
        let echeance: String?
        let principal: Bool
        let cleClient: UUID
    }

    private var nouvelObjectif: NouvelObjectif? {
        guard let objectif else { return nil }
        if objectif == "course" {
            guard let distance = distanceChoisie, distance > 0 else { return nil }
            let minutes = justeFinir ? nil : LibellesHAL.minutes(tempsVise)
            let km = (Double(distance) / 1000).formatted(.number.precision(.fractionLength(0...1)))
            return NouvelObjectif(
                type: "course", libelle: "\(km) km" + (minutes.map { " en \(LibellesHAL.duree($0))" } ?? ", la finir"),
                pilier: nil, distanceM: distance, cibleValeur: minutes.map { ($0 * 100).rounded() / 100 },
                cibleUnite: minutes == nil ? nil : "min", echeance: TexteHAL.jourISO(dateCourse),
                principal: true, cleClient: UUID())
        }
        let libelle = LibellesHAL.objectifs.first { $0.0 == objectif }?.1 ?? objectif
        return NouvelObjectif(type: "pilier", libelle: libelle, pilier: objectif, distanceM: nil,
                              cibleValeur: nil, cibleUnite: nil, echeance: nil, principal: true,
                              cleClient: UUID())
    }

    private struct TexteMemoire: Encodable { let texte: String }

    /// DEM-1 : ce qu'on a écrit en plus, écran par écran, va dans la mémoire de la
    /// semaine : HAL la relit à chaque appel (MEM-1).
    private func confierLesNotes() async {
        guard let client else { return }
        let lignes = notes.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lignes.isEmpty else { return }
        let memoire: MemoireHAL? = try? await client.requete("GET", "coach/memoire")
        let avant = memoire?.semaine?.texte ?? ""
        let ajout = "Dit au démarrage : " + lignes.joined(separator: " ; ")
        guard !avant.contains(ajout) else { return }
        let texte = String((avant.isEmpty ? ajout : avant + "\n" + ajout).prefix(4000))
        try? await client.envoyer("PUT", "coach/memoire/semaine", corps: ClientAPI.corps(TexteMemoire(texte: texte)))
    }

    /// 7.14 : l'objectif part, HAL donne son avis, puis construit le plan en
    /// arrière-plan. Le plan arrive en quelques minutes.
    private func construire() async {
        guard let client else { aller(.fini); return }
        envoi = true
        defer { envoi = false }
        await confierLesNotes()
        do {
            if let nouveau = nouvelObjectif {
                let cree: ObjectifCree = try await client.requete("POST", "objectifs",
                                                                  corps: ClientAPI.corps(nouveau), delai: 150)
                avis = cree.coach?.message
                if let manque = cree.coach?.planEnAttenteDe, !manque.isEmpty {
                    erreur = "Le plan attend encore : " + manque.joined(separator: ", ")
                }
            } else if principal != nil, etat?.plan != true {
                try await client.envoyer("POST", "plan/reconstruire")
            } else if principal == nil {
                erreur = "Choisis d'abord ton objectif."
                return
            }
            objectif = nil
            await rafraichir()
            aller(.construction)
            attendLePlan = true
            await attendreLePlan()
        } catch {
            erreur = Self.motif(error)
        }
    }

    /// Le plan se construit en quelques minutes : on regarde toutes les dix secondes.
    func attendreLePlan() async {
        guard let client else { return }
        for _ in 0..<60 {
            if let lu: PlanHAL = try? await client.requete("GET", "plan"), lu.plan != nil {
                plan = lu
                attendLePlan = false
                if page == .construction { aller(.plan) }
                return
            }
            try? await Task.sleep(for: .seconds(10))
            if Task.isCancelled { return }
        }
        attendLePlan = false
    }

    static func motif(_ erreur: Error) -> String {
        (erreur as? ErreurAPI)?.message ?? erreur.localizedDescription
    }
}
