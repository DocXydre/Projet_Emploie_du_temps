import BackgroundTasks
import Foundation
import SwiftUI
import UserNotifications

struct LigneJournal: Identifiable {
    let id = UUID()
    let quand: Date
    let texte: String
    let erreur: Bool
}

/// Lit Santé et envoie au serveur (opération C7). Une seule instance, partagée
/// par l'écran, la tâche de fond et le raccourci.
@MainActor
final class Synchro: ObservableObject {
    static let partage = Synchro()
    nonisolated static let idTache = "fr.docxydre.coachsante.synchro"

    @Published private(set) var enCours = false
    @Published private(set) var jours: [JourSante] = []
    @Published private(set) var seances: [SeanceMontre] = []
    @Published private(set) var journal: [LigneJournal] = []
    @Published private(set) var dernierEnvoi: Date?
    @Published private(set) var dernierEssai: Date?
    @Published private(set) var progression: String?

    let lecteur = LecteurSante()
    private let reglages = UserDefaults.standard

    private init() {
        dernierEnvoi = reglages.object(forKey: "dernier_envoi") as? Date
    }

    var adresse: String {
        get { reglages.string(forKey: "adresse") ?? "" }
        set { reglages.set(newValue, forKey: "adresse"); objectWillChange.send() }
    }

    /// Combien de jours envoyer au premier envoi. Ensuite, depuis le dernier
    /// envoi réussi, avec deux jours de marge : une nuit ou une séance arrive
    /// parfois tard dans Santé.
    var joursInitiaux: Int {
        get {
            let n = reglages.integer(forKey: "jours_initiaux")
            return n > 0 ? n : 14
        }
        set { reglages.set(newValue, forKey: "jours_initiaux"); objectWillChange.send() }
    }

    var client: ClientAPI? { ClientAPI(adresse: adresse, cle: Trousseau.lire()) }
    var estConfiguree: Bool { client != nil }

    private func noter(_ texte: String, erreur: Bool = false) {
        journal.insert(LigneJournal(quand: Date(), texte: texte, erreur: erreur), at: 0)
        if journal.count > 40 { journal.removeLast(journal.count - 40) }
    }

    private func debutDeLEnvoi() -> Date {
        let calendrier = Calendar.current
        let aujourdhui = calendrier.startOfDay(for: Date())
        guard let dernier = dernierEnvoi else {
            return calendrier.date(byAdding: .day, value: -(joursInitiaux - 1), to: aujourdhui)
                ?? aujourdhui
        }
        let depuis = calendrier.date(byAdding: .day, value: -2,
                                     to: calendrier.startOfDay(for: dernier)) ?? aujourdhui
        let plancher = calendrier.date(byAdding: .day, value: -30, to: aujourdhui) ?? aujourdhui
        return max(depuis, plancher)
    }

    /// Relit Santé sans rien envoyer : ce que l'écran montre.
    func relire() async {
        guard LecteurSante.disponible else { return }
        let depuis = Calendar.current.date(byAdding: .day, value: -6,
                                           to: Calendar.current.startOfDay(for: Date())) ?? Date()
        do {
            let lus = try await lecteur.jours(depuis: depuis)
            jours = Array(lus.reversed())
            seances = try await lecteur.seances(depuis: depuis)
        } catch {
            noter("Lecture de Santé impossible : \(error.localizedDescription)", erreur: true)
        }
    }

    /// Lit Santé et envoie les jours et les séances. Rend une phrase de bilan.
    @discardableResult
    func synchroniser(raison: String, depuis impose: Date? = nil) async -> String {
        guard !enCours else { return "Un envoi est déjà en cours." }
        guard LecteurSante.disponible else {
            noter("Santé n'est pas disponible sur cet appareil.", erreur: true)
            return "Santé n'est pas disponible sur cet appareil."
        }
        guard let client else {
            noter("Adresse du serveur ou clé d'API manquante : voir les réglages.", erreur: true)
            return "L'appli n'est pas configurée."
        }
        enCours = true
        dernierEssai = Date()
        defer { enCours = false }

        let debut = impose.map { Calendar.current.startOfDay(for: $0) } ?? debutDeLEnvoi()
        defer { progression = nil }
        var joursEnvoyes = 0
        var seancesEnvoyees = 0
        var echecs: [String] = []
        var injoignable = false

        do {
            progression = "Lecture de Santé…"
            let lus = try await lecteur.jours(depuis: debut).filter { !$0.estVide }
            for (rang, jour) in lus.enumerated() {
                if rang % 20 == 0 { progression = "Jours : \(rang) sur \(lus.count)" }
                do {
                    try await client.appeler("PUT", "/donnees-sante/jours/\(Format.jour(jour.jour))",
                                             corps: jour.corps)
                    joursEnvoyes += 1
                } catch {
                    echecs.append("\(Format.jour(jour.jour)) : \(error.localizedDescription)")
                    // Le serveur injoignable : inutile d'essayer le reste.
                    if error is URLError { injoignable = true; break }
                }
            }
            if !injoignable {
                let toutes = try await lecteur.seances(depuis: debut)
                for (rang, seance) in toutes.enumerated() {
                    if rang % 10 == 0 { progression = "Séances : \(rang) sur \(toutes.count)" }
                    do {
                        try await client.appeler("PUT",
                                                 "/donnees-sante/activites/\(seance.id.uuidString)",
                                                 corps: seance.corps)
                        seancesEnvoyees += 1
                    } catch {
                        echecs.append("\(seance.libelle) du \(Format.jour(seance.debut)) : "
                                      + error.localizedDescription)
                        if error is URLError { break }
                    }
                }
            }
        } catch {
            echecs.append("Lecture de Santé : \(error.localizedDescription)")
        }

        await relire()
        let bilan = "\(joursEnvoyes) jour(s) et \(seancesEnvoyees) séance(s) envoyés"
            + " depuis le \(Format.jour(debut))"
        if echecs.isEmpty {
            dernierEnvoi = Date()
            reglages.set(dernierEnvoi, forKey: "dernier_envoi")
            noter("\(bilan) (\(raison)).")
            return bilan + "."
        }
        noter("\(bilan), \(echecs.count) échec(s) (\(raison)). Premier : \(echecs[0])",
              erreur: true)
        return "\(bilan). \(echecs.count) échec(s) : \(echecs[0])"
    }

    /// Envoie tout ce que Santé contient, depuis la première donnée de pas. Les
    /// séances de plus de 28 jours sont gardées par le serveur sans devenir des
    /// séances libres (SAN-8). Garde l'appli ouverte pendant l'envoi.
    func envoyerTout() async -> String {
        let premiere: Date?
        do {
            premiere = try await lecteur.premiereDonnee()
        } catch {
            return "Lecture de Santé impossible : \(error.localizedDescription)"
        }
        guard let premiere else { return "Santé ne contient aucune donnée de pas." }
        return await synchroniser(raison: "tout l'historique", depuis: premiere)
    }

    /// Vérifie l'adresse et la clé, sans rien envoyer.
    func tester() async -> String {
        guard let client else { return "Il manque l'adresse ou la clé." }
        do {
            let rendu = try await client.appeler("GET", "/donnees-sante/fraicheur")
                as? [String: Any]
            let dernier = rendu?["dernier_envoi"] as? String
            return "Connexion réussie. Dernier envoi connu du serveur : \(dernier ?? "aucun")."
        } catch {
            return "Échec : \(error.localizedDescription)"
        }
    }

    // MARK: - Arrière-plan

    /// iOS décide de l'heure. Au plus tôt dans trois heures ; souvent la nuit,
    /// téléphone en charge. Santé est illisible téléphone verrouillé : l'envoi
    /// à l'ouverture de l'appli reste la voie sûre.
    nonisolated static func planifier() {
        let demande = BGAppRefreshTaskRequest(identifier: idTache)
        demande.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(demande)
    }

    func envoyerEnFond() async {
        Synchro.planifier()
        await synchroniser(raison: "arrière-plan")
    }

    /// À l'ouverture : un envoi si le dernier essai date de plus de quinze minutes.
    func aLOuverture() async {
        Synchro.planifier()
        await Profil.prevenirAvantExpiration()
        if let essai = dernierEssai, Date().timeIntervalSince(essai) < 15 * 60 {
            await relire()
            return
        }
        if estConfiguree {
            await synchroniser(raison: "ouverture")
        } else {
            await relire()
        }
    }
}

/// Le profil d'un compte Apple gratuit expire au bout de sept jours. L'appli
/// lit la date dans son propre profil et prévient la veille.
enum Profil {
    static let expiration: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let donnees = try? Data(contentsOf: url),
              let texte = String(data: donnees, encoding: .isoLatin1),
              let debut = texte.range(of: "<?xml"),
              let fin = texte.range(of: "</plist>"),
              let plist = String(texte[debut.lowerBound..<fin.upperBound])
                  .data(using: .isoLatin1),
              let objet = try? PropertyListSerialization.propertyList(from: plist, format: nil)
                  as? [String: Any]
        else { return nil }
        return objet["ExpirationDate"] as? Date
    }()

    static func prevenirAvantExpiration() async {
        guard let expiration else { return }
        let centre = UNUserNotificationCenter.current()
        guard (try? await centre.requestAuthorization(options: [.alert, .sound])) == true else {
            return
        }
        let veille = expiration.addingTimeInterval(-24 * 3600)
        guard veille > Date() else { return }
        let contenu = UNMutableNotificationContent()
        contenu.title = "Coach Santé expire demain"
        contenu.body = "Branche l'iPhone au Mac et relance l'appli depuis Xcode (Cmd+R). "
            + "Tes réglages sont gardés."
        let composants = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                         from: veille)
        let declencheur = UNCalendarNotificationTrigger(dateMatching: composants, repeats: false)
        centre.removePendingNotificationRequests(withIdentifiers: ["expiration"])
        try? await centre.add(UNNotificationRequest(identifier: "expiration", content: contenu,
                                                    trigger: declencheur))
    }
}
