import SwiftUI
import Observation

/// L'état de l'orbe (ORB-4).
enum EtatOrbe: Equatable {
    case repos
    /// HAL réfléchit : l'iris tourne.
    case active
    /// HAL a quelque chose à dire : un « ! » à la place de l'iris.
    case recap
}

/// La conversation avec HAL, partagée par toute l'appli : elle survit aux
/// changements d'onglet (ORB-2). Connectée, elle parle au serveur ; en
/// démonstration, HAL répond par une phrase d'attente.
@MainActor
@Observable
final class ConversationHAL {
    private static let messageDeDemonstration = MessageHAL(
        id: "demo", auteur: .hal,
        texte: "Salut. Ta semaine est validée : trois séances, dont la course de jeudi.")

    private(set) var messages: [MessageHAL] = [ConversationHAL.messageDeDemonstration]
    var ouvert = false
    /// ORB-12 : le panneau monte jusqu'en haut de l'écran.
    var etendu = false
    var dictee = false
    private(set) var reflechit = false
    private(set) var echec = false
    /// Ce que HAL est en train de regarder, affiché pendant qu'il réfléchit (ORB-7).
    private(set) var regarde = ""
    /// L'onglet affiché (ORB-3, COA-33).
    var contexte = "Aujourd'hui"
    /// La séance, la semaine ou l'écran ouvert dans l'onglet, s'il y en a un.
    var detail: String?
    /// L'élément sur lequel on demande un changement, joint en haut du panneau (COA-32).
    var joint: ElementJoint?
    /// Quelque chose attend d'être lu : le récap, un ajustement, une réponse arrivée panneau fermé.
    var aQuelqueChoseADire = false
    /// HAL n'est pas activé pour ce compte : le panneau propose le démarrage (DEM-1).
    private(set) var inactif = false
    /// Le message parti sans réponse : il est gardé sur le téléphone (ORB-8).
    private(set) var enAttente: DemandeEnAttente?
    /// Les éléments réglés depuis le panneau, avec ce qui a été fait : leurs
    /// boutons disparaissent tout de suite, sans attendre le serveur.
    private(set) var faits: [String: String] = [:]
    /// Le démarrage de HAL, ouvert par-dessus tout (DEM-1) : depuis Sport, l'orbe ou Réglages.
    var demarrageOuvert = false

    /// Le serveur, posé par l'appli quand la session est ouverte.
    var client: ClientAPI? {
        didSet {
            if client == nil {
                messages = [Self.messageDeDemonstration]
                inactif = false
            }
        }
    }
    /// Ce qu'il faut recharger après une action faite depuis le panneau.
    var apresAction: (() async -> Void)?

    init() {
        enAttente = Self.lireLAttente()
    }

    /// Ce que HAL voit, en clair : « Sport · Semaine du 12 oct. ».
    var voit: String {
        [contexte, detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// 2.5 : ce que dit la bulle au-dessus de l'orbe, selon le dernier mot de HAL.
    var cequIlADit: String {
        guard let dernier = messages.last(where: { $0.auteur == .hal }) else { return "HAL a quelque chose à te dire" }
        if dernier.moment == "synthese" { return "HAL a fait le point de ta journée" }
        if dernier.elements.contains(where: { $0.type == "ajustement" && $0.regle == nil }) {
            return "HAL propose un ajustement"
        }
        return "HAL t'a répondu"
    }

    var etatOrbe: EtatOrbe {
        if reflechit { return .active }
        if aQuelqueChoseADire && !ouvert { return .recap }
        return .repos
    }

    // MARK: Ouvrir et fermer

    func ouvrir(dictee: Bool = false) {
        withAnimation(.smooth(duration: 0.35)) {
            ouvert = true
            self.dictee = dictee
            aQuelqueChoseADire = false
        }
        Task { await vu() }
    }

    func fermer() {
        withAnimation(.smooth(duration: 0.3)) {
            ouvert = false
            etendu = false
            dictee = false
        }
    }

    /// ORB-12 : de la moitié de l'écran jusqu'en haut, et retour.
    func etendre(_ voulu: Bool) {
        withAnimation(.smooth(duration: 0.3)) { etendu = voulu }
    }

    /// « Demander un changement », sur une séance, une course ou la semaine (ORB-10).
    func demanderUnChangement(_ element: ElementJoint) {
        joint = element
        ouvrir()
    }

    /// NOT-18 : le « ! » s'efface quand on ouvre le panneau, et ce qui est arrivé
    /// entre-temps s'affiche.
    private func vu() async {
        guard let client else { return }
        try? await client.envoyer("POST", "moi/orbe/vu")
        await charger()
    }

    /// Le serveur dit que HAL a parlé : le récap du soir, un ajustement (NOT-18).
    func signaler() {
        if !ouvert { aQuelqueChoseADire = true }
    }

    // MARK: L'historique

    /// Les derniers échanges, du plus ancien au plus récent. Un message en
    /// attente reste en bas, et repart s'il le peut.
    func charger() async {
        guard let client else { return }
        do {
            let lus: [MessageHAL] = try await client.requete("GET", "coach/echanges?limite=40")
            var suite = Array(lus.reversed())
            if let enAttente {
                suite.append(MessageHAL(id: enAttente.cleClient.uuidString, auteur: .moi,
                                        texte: enAttente.texte, enAttente: true))
            }
            if suite.isEmpty {
                suite = [MessageHAL(id: "accueil", auteur: .hal,
                                    texte: "Je suis là. Pose-moi une question, ou dis-moi ce qui change.")]
            }
            messages = suite
            if enAttente != nil && !reflechit { await envoyerLAttente() }
        } catch {
            // Hors réseau : on garde ce qu'on a, et le message en attente reste
            // visible en bas, avec de quoi le renvoyer (8.11).
            if let enAttente {
                if !messages.contains(where: { $0.id == enAttente.cleClient.uuidString }) {
                    messages.append(MessageHAL(id: enAttente.cleClient.uuidString, auteur: .moi,
                                               texte: enAttente.texte, enAttente: true))
                }
                echec = true
            }
        }
    }

    // MARK: Envoyer

    /// Un message libre. Avec un élément joint, c'est une demande de changement.
    /// `moment` force un signalement depuis les réponses prêtes (ORB-11).
    func envoyer(_ texte: String, moment: String? = nil, horsReseau: Bool = false,
                 hal: String? = nil) {
        let propre = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !propre.isEmpty, !reflechit, enAttente == nil else { return }
        guard client != nil else {
            messages.append(MessageHAL(id: UUID().uuidString, auteur: .moi, texte: propre))
            repondreEnDemonstration(horsReseau: horsReseau)
            return
        }
        let demande = DemandeEnAttente(
            texte: propre, cleClient: UUID(),
            moment: joint != nil ? "changement" : (moment ?? "question"),
            joint: joint, ecran: voit, hal: hal)
        enAttente = demande
        Self.garder(demande)
        // AIG-4 : le texte renvoyé avec « Maison » ou « Sport » est déjà affiché.
        if hal == nil {
            messages.append(MessageHAL(id: demande.cleClient.uuidString, auteur: .moi, texte: propre,
                                       enAttente: true))
        }
        Task { await envoyerLAttente() }
    }

    func reessayer(horsReseau: Bool = false) {
        guard client != nil else {
            repondreEnDemonstration(horsReseau: horsReseau)
            return
        }
        Task { await envoyerLAttente() }
    }

    /// « Plus tard » : le message reste gardé, il repartira à la prochaine ouverture.
    func plusTard() {
        echec = false
        fermer()
    }

    private func envoyerLAttente() async {
        guard let client, let demande = enAttente, !reflechit else { return }
        echec = false
        reflechit = true
        regarde = Self.phrase(demande)
        defer { reflechit = false }
        let corps = ClientAPI.corps(EnvoiAHAL(
            texte: demande.texte, cleClient: demande.cleClient, ecran: String(demande.ecran.prefix(200)),
            idOccurrence: demande.joint?.idOccurrence,
            lundi: demande.joint?.lundi.map(TexteHAL.jourISO), hal: demande.hal))
        do {
            // COA-16 : le serveur répond une fois HAL terminé, quatre-vingt-dix
            // secondes au plus. La même clé renvoyée ne relance rien (COA-24).
            let reponse: MessageHAL = try await client.requete(
                "POST", "coach/\(demande.moment)", corps: corps, delai: 150)
            oublierLAttente(demande)
            if demande.joint != nil { joint = nil }
            messages.append(reponse)
            if !ouvert { aQuelqueChoseADire = true }
            await apresAction?()
        } catch let erreur as ErreurAPI where erreur.injoignable {
            echec = true
            if !ouvert { aQuelqueChoseADire = true }
        } catch let erreur as ErreurAPI {
            oublierLAttente(demande)
            if erreur.code == "coach_inactif" {
                inactif = true
            } else {
                messages.append(MessageHAL(id: UUID().uuidString, auteur: .systeme, texte: erreur.message))
            }
        } catch {
            echec = true
        }
    }

    private func oublierLAttente(_ demande: DemandeEnAttente) {
        if let rang = messages.firstIndex(where: { $0.id == demande.cleClient.uuidString }) {
            messages[rang].enAttente = false
        }
        enAttente = nil
        Self.garder(nil)
    }

    /// ORB-7 : une phrase qui dit ce que HAL regarde.
    private static func phrase(_ demande: DemandeEnAttente) -> String {
        if let joint = demande.joint {
            return joint.genre == .seance ? "Je regarde la séance et ta semaine…"
                : "Je regarde ta semaine et ton emploi du temps…"
        }
        switch demande.moment {
        case "signalement": return "Je regarde tes séances et ta récupération…"
        default: return "Je relis ton planning et nos derniers échanges…"
        }
    }

    private func repondreEnDemonstration(horsReseau: Bool) {
        echec = false
        reflechit = true
        regarde = "Je regarde ton planning et ta récupération…"
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            reflechit = false
            if horsReseau {
                echec = true
                return
            }
            messages.append(MessageHAL(id: UUID().uuidString, auteur: .hal,
                                       texte: "Je suis branché sur des données d'essai. Connecte l'appli au serveur pour que je te réponde vraiment (je vois : \(voit))."))
            if !ouvert { aQuelqueChoseADire = true }
        }
    }

    // MARK: Les boutons des éléments

    /// ORB-6 : une action validée dans le panneau le referme et s'annonce cinq
    /// secondes avec « Annuler ». Elle ne part qu'à la fin de ce délai : annuler
    /// ne laisse donc rien à défaire sur le serveur.
    func agir(_ action: ActionHAL, sur element: String, confirmation: String, annoncer: AnnonceurAction) {
        guard faits[element] == nil else { return }
        faits[element] = confirmation
        guard let client else {
            annoncer(confirmation)
            return
        }
        fermer()
        let tache = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            do {
                try await client.envoyer(action.methode, action.chemin)
                await self?.apresAction?()
                await self?.charger()
            } catch {
                let motif = (error as? ErreurAPI)?.message ?? error.localizedDescription
                self?.faits[element] = nil
                self?.messages.append(MessageHAL(id: UUID().uuidString, auteur: .systeme,
                                                 texte: "« \(action.libelle) » n'a pas pu se faire : \(motif)"))
                self?.aQuelqueChoseADire = true
            }
        }
        annoncer(confirmation, annuler: { [weak self] in
            tache.cancel()
            self?.faits[element] = nil
        })
    }

    // MARK: Le message gardé

    private static var fichierAttente: URL { Foyer.fichier("hal-en-attente.json") }

    private static func garder(_ demande: DemandeEnAttente?) {
        guard let demande, let donnees = try? JSONEncoder().encode(demande) else {
            try? FileManager.default.removeItem(at: fichierAttente)
            return
        }
        try? donnees.write(to: fichierAttente, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func lireLAttente() -> DemandeEnAttente? {
        guard let donnees = try? Data(contentsOf: fichierAttente) else { return nil }
        return try? JSONDecoder().decode(DemandeEnAttente.self, from: donnees)
    }
}

/// Un écran dit à HAL ce qu'il montre (ORB-3) : la séance, la semaine, un réglage.
private struct VuParHAL: ViewModifier {
    let detail: String
    @Environment(ConversationHAL.self) private var conversation

    func body(content: Content) -> some View {
        content
            .onAppear { conversation.detail = detail }
            .onChange(of: detail) { conversation.detail = detail }
            .onDisappear { if conversation.detail == detail { conversation.detail = nil } }
    }
}

extension View {
    func vuParHAL(_ detail: String) -> some View {
        modifier(VuParHAL(detail: detail))
    }
}
