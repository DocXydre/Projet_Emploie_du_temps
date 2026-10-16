import SwiftUI

// Ce que lisent l'onglet Sport [3.1], Maison [4.1] et les widgets Semaine,
// Week-end, Train, Montre et Dernière course. Tout vient de routes déjà là :
// le planning, les trains retenus, le plan, la semaine de sport, Santé, la
// progression et les mesures. Le foyer les lit à chaque chargement ; les
// widgets ne calculent rien de plus que leur mise en forme (WID-8).

/// Une ligne de `GET /planning` : une tâche, une occupation, une proposition.
struct ElementPlanning: Codable, Hashable, Sendable {
    let nature: String
    let id: Int
    let idUtilisateur: Int?
    let categorie: String?
    let libelle: String
    let debut: Date
    let fin: Date?
    let journeeEntiere: Bool?
    let statut: String?
    let lieu: String?
    /// NOT-17 : la raison d'un changement, « déplacée par HAL ».
    let motif: String?

    /// Une ligne se reconnaît à sa nature et à son numéro.
    var cle: String { "\(nature)-\(id)" }

    /// La famille de couleur de l'appli (C.4), comme `/appli/aujourdhui` la donne.
    var famille: Categorie {
        switch categorie {
        case "animal": .chat
        case "vaisselle", "menage": .menage
        case "linge": .linge
        case "sport": .sport
        case "cours": .cours
        case "travail": .travail
        default: .perso
        }
    }

    var estUneTache: Bool { nature == "tache" }
}

/// Un train retenu à venir, `GET /trajets`.
struct TrainRetenu: Codable, Hashable, Identifiable, Sendable {
    let idTrajet: Int
    let sens: String
    let depart: Date
    let arrivee: Date
    let origine: String
    let destination: String
    let correspondances: Int?
    let resume: String?
    var id: Int { idTrajet }
}

struct Complements: Sendable {
    /// Du lundi de cette semaine à neuf jours d'ici, pour tout le foyer.
    var planning: [ElementPlanning] = []
    var trains: [TrainRetenu] = []
    var plan: PlanHAL?
    var semaine: SemaineDeSport?
    /// Santé reçue par le serveur et séances de la montre, sur `joursDeSante` jours.
    var sante: HistoriqueSante?
    var joursDeSante = 30
    var progression: [SemaineDExercice] = []
    var mesures: [MesureSaisie] = []
}

extension Foyer {
    /// Lit les compléments, chacun pour soi : une route qui échoue laisse les
    /// autres s'afficher, et garde sa dernière valeur.
    func chargerComplements(_ client: ClientAPI) async {
        let calendrier = Calendar.current
        let aujourdhui = calendrier.startOfDay(for: .now)
        let lundi = calendrier.date(from: calendrier.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                                     from: aujourdhui)) ?? aujourdhui
        let fin = calendrier.date(byAdding: .day, value: 9, to: aujourdhui) ?? aujourdhui
        let iso = ISO8601DateFormatter()
        let jours = complements.joursDeSante

        async let planning: [ElementPlanning]? = try? client.requete(
            "GET", "planning?debut=\(iso.string(from: lundi))&fin=\(iso.string(from: fin))")
        async let trains: [TrainRetenu]? = try? client.requete("GET", "trajets")
        async let plan: PlanHAL? = try? client.requete("GET", "plan")
        async let semaine: SemaineDeSport? = try? client.requete("GET", "appli/semaine")
        async let sante: HistoriqueSante? = try? client.requete("GET", "appli/sante?jours=\(jours)")
        async let progression: [SemaineDExercice]? = try? client.requete("GET", "appli/progression")
        async let mesures: [MesureSaisie]? = try? client.requete("GET", "appli/mesures")

        if let lu = await planning { complements.planning = lu }
        if let lu = await trains { complements.trains = lu }
        if let lu = await plan { complements.plan = lu }
        if let lu = await semaine { complements.semaine = lu }
        if let lu = await sante { complements.sante = lu }
        if let lu = await progression { complements.progression = lu }
        if let lu = await mesures { complements.mesures = lu }
    }

    /// 3.1 : la période de l'évolution, 7, 30 ou 90 jours.
    func changerLaPeriodeDeSante(_ jours: Int) async {
        complements.joursDeSante = jours
        guard let client else { return }
        if let lu: HistoriqueSante = try? await client.requete("GET", "appli/sante?jours=\(jours)") {
            complements.sante = lu
        }
    }

    // MARK: Ce que les widgets lisent

    /// Les tâches du foyer des prochains jours, aujourd'hui exclu, sans le sport (4.1).
    var bientot: [ElementPlanning] {
        let demain = Calendar.current.date(byAdding: .day, value: 1,
                                           to: Calendar.current.startOfDay(for: .now)) ?? .now
        return complements.planning.filter {
            $0.estUneTache && $0.famille != .sport && $0.debut >= demain
                && $0.statut != "faite"
        }
    }

    /// Le linge qui vient, aujourd'hui compris (4.1).
    var lingeAVenir: [ElementPlanning] {
        let aujourdhui = Calendar.current.startOfDay(for: .now)
        return complements.planning.filter {
            $0.estUneTache && $0.famille == .linge && ($0.fin ?? $0.debut) >= aujourdhui
                && $0.statut != "faite"
        }
    }

    /// Ma semaine, du lundi au dimanche, pour le widget Semaine [1.12].
    var maSemaine: [ElementPlanning] {
        complements.planning.filter { $0.idUtilisateur == moi.id && $0.nature != "proposition" }
    }

    /// Le prochain train retenu.
    var prochainTrain: TrainRetenu? { complements.trains.first }

    /// Les séances de la montre, de la plus récente à la plus ancienne.
    var seancesDeLaMontre: [HistoriqueSante.Activite] { complements.sante?.seances ?? [] }

    var derniereCourse: HistoriqueSante.Activite? {
        seancesDeLaMontre.first { $0.discipline == "course" }
    }

    /// Un membre du foyer, par son numéro.
    func membre(numero: Int?) -> Membre? {
        membres.first { $0.id == numero }
    }
}

extension Foyer {
    /// La couleur d'une personne : moi en bleu, l'autre en lilas, comme la maquette.
    func couleur(de membre: Membre?) -> Color {
        membre?.id == moi.id || membre == nil ? Categorie.travail.couleur : Categorie.linge.couleur
    }
}

/// Les dates et les durées telles que l'appli les écrit, en français.
enum EnFrancais {
    private static let francais = Locale(identifier: "fr_FR")

    /// « Mer. »
    static func jourCourt(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(francais)).capitalized
    }

    /// « mer. 14 oct. »
    static func jour(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(francais))
    }

    /// « 17:42 »
    static func heure(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(francais))
    }

    /// « 1 h 24 », « 45 min »
    static func duree(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    /// « 27:12 » pour 1 632 secondes
    static func chrono(_ secondes: Int) -> String {
        secondes >= 3600
            ? "\(secondes / 3600):\(String(format: "%02d:%02d", secondes % 3600 / 60, secondes % 60))"
            : "\(secondes / 60):\(String(format: "%02d", secondes % 60))"
    }

    /// « 5,21 km »
    static func distance(_ metres: Int) -> String {
        (Double(metres) / 1000).formatted(.number.precision(.fractionLength(0...2)).locale(francais)) + " km"
    }

    /// Le matériel d'un exercice, tel que le catalogue le code.
    static func materiel(_ code: String) -> String {
        switch code {
        case "barre": "Barre"
        case "halteres": "Haltères"
        case "machine": "Machine"
        case "poulie": "Poulie"
        case "poids_du_corps": "Poids du corps"
        case "cardio": "Cardio"
        case "aucun": "Sans matériel"
        default: code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Le groupe musculaire d'un exercice, tel que le catalogue le code.
    static func groupe(_ code: String) -> String {
        switch code {
        case "abdominaux": "Abdominaux"
        case "adducteurs": "Adducteurs"
        case "avant_bras": "Avant-bras"
        case "biceps": "Biceps"
        case "cardio": "Cardio"
        case "dos": "Dos"
        case "epaules": "Épaules"
        case "fessiers": "Fessiers"
        case "ischios": "Ischio-jambiers"
        case "lombaires": "Lombaires"
        case "mollets": "Mollets"
        case "pectoraux": "Pectoraux"
        case "quadriceps": "Quadriceps"
        case "triceps": "Triceps"
        default: code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// « 8 412 »
    static func nombre(_ valeur: Int) -> String {
        valeur.formatted(.number.locale(francais))
    }
}
