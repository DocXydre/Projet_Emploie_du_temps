import Foundation

/// Un exercice du catalogue, tel que `GET /exercices` le rend.
struct Exercice: Identifiable, Hashable {
    let id: Int
    let code: String
    let libelle: String
    let groupe: String
    let mesure: String          // charge_reps, duree ou distance
    let derniereSaisie: String? // ISO : se trie comme une date

    var enDuree: Bool { mesure == "duree" }
    var enDistance: Bool { mesure == "distance" }
}

/// Une série enregistrée sur le serveur.
struct SerieFaite: Identifiable, Hashable {
    let id: Int
    let code: String
    let libelle: String
    let numero: Int
    let chargeKg: Double?
    let repetitions: Int?
    let dureeSecondes: Int?
    let distanceM: Int?

    var enClair: String { Mesure.enClair(charge: chargeKg, reps: repetitions,
                                         duree: dureeSecondes, distance: distanceM) }
}

/// Un exercice fait dans la séance, avec ses séries.
struct ExerciceFait: Identifiable {
    let code: String
    let libelle: String
    let series: [SerieFaite]
    var id: String { code }
}

/// Une ligne prévue par le coach dans la séance du jour.
struct LignePrevue: Identifiable, Hashable {
    let id: Int                 // id_seance_exercice
    let code: String
    let libelle: String
    let mesure: String
    let series: Int?
    let repsMin: Int?
    let repsMax: Int?
    let chargeKg: Double?
    let dureeSecondes: Int?

    var enClair: String {
        var morceaux: [String] = []
        if let series { morceaux.append("\(series) séries") }
        if let repsMin, let repsMax {
            morceaux.append(repsMin == repsMax ? "\(repsMin) reps" : "\(repsMin) à \(repsMax) reps")
        }
        if let chargeKg { morceaux.append(Mesure.kg(chargeKg)) }
        if let dureeSecondes { morceaux.append("\(dureeSecondes) s") }
        return morceaux.joined(separator: ", ")
    }
}

enum Mesure {
    static func kg(_ valeur: Double) -> String {
        let texte = valeur.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(valeur)) : String(format: "%.1f", valeur).replacingOccurrences(of: ".", with: ",")
        return "\(texte) kg"
    }

    static func enClair(charge: Double?, reps: Int?, duree: Int?, distance: Int?) -> String {
        if let duree { return "\(duree) s" }
        if let distance { return "\(distance) m" }
        switch (charge, reps) {
        case let (c?, r?): return "\(kg(c)) × \(r)"
        case let (nil, r?): return "\(r) reps"
        case let (c?, nil): return kg(c)
        default: return "série"
        }
    }

    /// Les nombres du JSON arrivent en NSNumber : 42.5 n'est pas un Int.
    static func nombre(_ valeur: Any?) -> Double? {
        if let n = valeur as? NSNumber { return n.doubleValue }
        if let s = valeur as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    static func entier(_ valeur: Any?) -> Int? { nombre(valeur).map { Int($0.rounded()) } }
}

/// La séance de musculation en cours (SAI-14) : lancée, remplie série par série,
/// puis close avec son bilan. Une seule à la fois ; elle survit à la fermeture de
/// l'appli, son numéro est gardé dans les réglages.
@MainActor
final class SeanceEnCours: ObservableObject {
    static let partage = SeanceEnCours()

    @Published private(set) var idOccurrence: Int?
    @Published private(set) var debut: Date?
    @Published private(set) var titre = "Séance de musculation"
    @Published private(set) var prevu: [LignePrevue] = []
    @Published private(set) var series: [SerieFaite] = []
    @Published private(set) var catalogue: [Exercice] = []
    @Published private(set) var occupe = false
    @Published var erreur: String?

    private let reglages = UserDefaults.standard
    private var client: ClientAPI? { Synchro.partage.client }

    private init() {
        let id = reglages.integer(forKey: "seance_en_cours")
        idOccurrence = id > 0 ? id : nil
        debut = reglages.object(forKey: "seance_en_cours_debut") as? Date
    }

    var enCours: Bool { idOccurrence != nil }

    /// Les exercices dans l'ordre où ils ont été faits, avec leurs séries.
    var parExercice: [ExerciceFait] {
        var ordre: [String] = []
        var groupes: [String: [SerieFaite]] = [:]
        for serie in series {
            if groupes[serie.code] == nil { ordre.append(serie.code) }
            groupes[serie.code, default: []].append(serie)
        }
        return ordre.map { code in
            let liste = groupes[code] ?? []
            return ExerciceFait(code: code, libelle: liste.first?.libelle ?? code,
                                series: liste.sorted { $0.numero < $1.numero })
        }
    }

    func seriesDe(_ code: String) -> [SerieFaite] {
        series.filter { $0.code == code }.sorted { $0.numero < $1.numero }
    }

    func exercice(code: String) -> Exercice? { catalogue.first { $0.code == code } }

    // MARK: Lancer

    /// Reprend la séance du coach prévue aujourd'hui s'il y en a une, sinon ouvre
    /// une séance libre.
    func demarrer() async {
        guard let client else { erreur = "Règle d'abord l'adresse et la clé."; return }
        occupe = true
        defer { occupe = false }
        do {
            let duJour = try await client.appeler("GET", "/seances/aujourd-hui") as? [[String: Any]] ?? []
            let prevue = duJour.first { detail in
                let s = detail["seance"] as? [String: Any] ?? [:]
                let situation = s["situation"] as? String ?? ""
                return s["discipline"] as? String == "musculation"
                    && !["faite", "pas_faite", "remplacee", "retiree"].contains(situation)
            }
            let detail: [String: Any]
            if let prevue {
                detail = prevue
            } else {
                detail = try await client.appeler("POST", "/seances/libre", corps: [
                    "discipline": "musculation", "cle_client": UUID().uuidString,
                ]) as? [String: Any] ?? [:]
            }
            guard let id = Mesure.entier((detail["seance"] as? [String: Any])?["id_occurrence"])
            else { throw ErreurAPI(message: "Le serveur n'a pas rendu de séance") }
            idOccurrence = id
            debut = Date()
            reglages.set(id, forKey: "seance_en_cours")
            reglages.set(debut, forKey: "seance_en_cours_debut")
            lire(detail)
            if catalogue.isEmpty { await chargerCatalogue() }
        } catch {
            erreur = error.localizedDescription
        }
    }

    func recharger() async {
        guard let client, let idOccurrence else { return }
        do {
            let detail = try await client.appeler("GET", "/seances/\(idOccurrence)") as? [String: Any]
            if let detail { lire(detail) }
            if catalogue.isEmpty { await chargerCatalogue() }
        } catch {
            erreur = error.localizedDescription
        }
    }

    func chargerCatalogue() async {
        guard let client else { return }
        do {
            let lignes = try await client.appeler("GET", "/exercices?discipline=musculation")
                as? [[String: Any]] ?? []
            catalogue = lignes.compactMap { e in
                // SEC-1 : un exercice qu'une limitation interdit n'est pas proposé.
                guard (e["interdit"] as? Bool) != true,
                      let id = Mesure.entier(e["id_exercice"]),
                      let code = e["code"] as? String else { return nil }
                return Exercice(id: id, code: code, libelle: e["libelle"] as? String ?? code,
                                groupe: e["groupe_principal"] as? String ?? "autre",
                                mesure: e["mesure"] as? String ?? "charge_reps",
                                derniereSaisie: e["derniere_saisie"] as? String)
            }
        } catch {
            erreur = error.localizedDescription
        }
    }

    private func lire(_ detail: [String: Any]) {
        let seance = detail["seance"] as? [String: Any] ?? [:]
        if let type = seance["type_seance"] as? String, !type.isEmpty { titre = type.capitalized }
        prevu = (detail["prevu"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = Mesure.entier(p["id_seance_exercice"]),
                  let code = p["code"] as? String else { return nil }
            return LignePrevue(id: id, code: code, libelle: p["libelle"] as? String ?? code,
                               mesure: p["mesure"] as? String ?? "charge_reps",
                               series: Mesure.entier(p["series"]),
                               repsMin: Mesure.entier(p["repetitions_min"]),
                               repsMax: Mesure.entier(p["repetitions_max"]),
                               chargeKg: Mesure.nombre(p["charge_kg"]),
                               dureeSecondes: Mesure.entier(p["duree_secondes"]))
        }
        series = (detail["saisi"] as? [[String: Any]] ?? []).compactMap { s in
            guard let id = Mesure.entier(s["id_serie"]), let code = s["code"] as? String
            else { return nil }
            return SerieFaite(id: id, code: code, libelle: s["libelle"] as? String ?? code,
                              numero: Mesure.entier(s["numero"]) ?? 0,
                              chargeKg: Mesure.nombre(s["charge_kg"]),
                              repetitions: Mesure.entier(s["repetitions"]),
                              dureeSecondes: Mesure.entier(s["duree_secondes"]),
                              distanceM: Mesure.entier(s["distance_m"]))
        }
    }

    // MARK: Les séries

    /// Les séries de la dernière séance où cet exercice a été fait.
    func derniereFois(_ code: String) async -> [SerieFaite] {
        guard let client else { return [] }
        let suite = idOccurrence.map { "?avant=\($0)" } ?? ""
        let rendu = try? await client.appeler("GET", "/exercices/\(code)/derniere-fois\(suite)")
            as? [String: Any]
        return (rendu?["series"] as? [[String: Any]] ?? []).enumerated().map { rang, s in
            SerieFaite(id: -rang - 1, code: code, libelle: code,
                       numero: Mesure.entier(s["numero"]) ?? rang + 1,
                       chargeKg: Mesure.nombre(s["charge_kg"]),
                       repetitions: Mesure.entier(s["repetitions"]),
                       dureeSecondes: Mesure.entier(s["duree_secondes"]),
                       distanceM: Mesure.entier(s["distance_m"]))
        }
    }

    /// Enregistre une série. La clé d'appareil évite un doublon si l'envoi est
    /// répété (SAI-9). Rend vrai si la série est en base.
    func ajouterSerie(code: String, ligne: Int?, charge: Double?, reps: Int?,
                      duree: Int?, distance: Int?) async -> Bool {
        guard let client, let idOccurrence else { return false }
        var corps: [String: Any] = ["code": code, "cle_client": UUID().uuidString]
        if let charge { corps["charge_kg"] = charge }
        if let reps { corps["repetitions"] = reps }
        if let duree { corps["duree_secondes"] = duree }
        if let distance { corps["distance_m"] = distance }
        if let ligne { corps["id_seance_exercice"] = ligne }
        occupe = true
        defer { occupe = false }
        do {
            let rendu = try await client.appeler("POST", "/seances/\(idOccurrence)/series",
                                                 corps: corps) as? [String: Any]
            let resultat = (rendu?["series"] as? [[String: Any]])?.first ?? [:]
            if resultat["etat"] as? String == "refusee" {
                erreur = resultat["message"] as? String ?? "Série refusée"
                return false
            }
            await recharger()
            return true
        } catch {
            erreur = error.localizedDescription
            return false
        }
    }

    func supprimer(_ serie: SerieFaite) async {
        guard let client, let idOccurrence else { return }
        do {
            try await client.appeler("DELETE", "/seances/\(idOccurrence)/series/\(serie.id)")
            await recharger()
        } catch {
            erreur = error.localizedDescription
        }
    }

    // MARK: Clore

    /// Le bilan : effort, durée, commentaire. Avec l'avis du coach, l'appel peut
    /// prendre une minute. Rend le message du coach s'il y en a un.
    func terminer(effort: Int, minutes: Int, commentaire: String, avisDuCoach: Bool) async -> String? {
        guard let client, let idOccurrence else { return nil }
        var corps: [String: Any] = ["effort": effort, "duree_minutes": max(minutes, 1),
                                    "cle_client": UUID().uuidString]
        let texte = commentaire.trimmingCharacters(in: .whitespacesAndNewlines)
        if !texte.isEmpty { corps["commentaire"] = texte }
        occupe = true
        defer { occupe = false }
        do {
            let rendu = try await client.appeler(
                "POST", "/seances/\(idOccurrence)/bilan?appeler_coach=\(avisDuCoach)",
                corps: corps, delai: avisDuCoach ? 150 : 20) as? [String: Any]
            oublier()
            let coach = rendu?["coach"] as? [String: Any]
            return coach?["message"] as? String ?? "Séance close."
        } catch {
            erreur = error.localizedDescription
            return nil
        }
    }

    /// Oublie la séance sur l'iPhone. Elle reste sur le serveur : ses séries
    /// comptent, et la clôture du soir la juge.
    func oublier() {
        idOccurrence = nil
        debut = nil
        prevu = []
        series = []
        titre = "Séance de musculation"
        reglages.removeObject(forKey: "seance_en_cours")
        reglages.removeObject(forKey: "seance_en_cours_debut")
    }
}
