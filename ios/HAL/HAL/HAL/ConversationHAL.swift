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
/// changements d'onglet (ORB-2).
@MainActor
@Observable
final class ConversationHAL {
    private(set) var messages: [Message] = [
        Message(auteur: .hal, texte: "Salut. Ta semaine est validée : trois séances, dont la course de jeudi."),
    ]
    var ouvert = false
    var dictee = false
    private(set) var reflechit = false
    private(set) var echec = false
    /// Ce que HAL est en train de regarder, affiché pendant qu'il réfléchit (ORB-7).
    private(set) var regarde = ""
    /// L'onglet affiché, donné à HAL avec chaque message (ORB-3, COA-33).
    var contexte = "Aujourd'hui"
    /// Quelque chose attend d'être lu : le récap, un ajustement, une réponse arrivée panneau fermé.
    var aQuelqueChoseADire = false

    var etatOrbe: EtatOrbe {
        if reflechit { return .active }
        if aQuelqueChoseADire && !ouvert { return .recap }
        return .repos
    }

    func ouvrir(dictee: Bool = false) {
        withAnimation(.smooth(duration: 0.35)) {
            ouvert = true
            self.dictee = dictee
            aQuelqueChoseADire = false
        }
    }

    func fermer() {
        withAnimation(.smooth(duration: 0.3)) {
            ouvert = false
            dictee = false
        }
    }

    /// Envoie un message. Sans serveur, HAL répond par une phrase d'attente.
    func envoyer(_ texte: String, horsReseau: Bool) {
        let propre = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !propre.isEmpty, !reflechit else { return }
        messages.append(Message(auteur: .moi, texte: propre))
        attendreLaReponse(horsReseau: horsReseau)
    }

    func reessayer(horsReseau: Bool) {
        attendreLaReponse(horsReseau: horsReseau)
    }

    private func attendreLaReponse(horsReseau: Bool) {
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
            messages.append(Message(auteur: .hal, texte: "Je suis branché sur des données d'essai pour l'instant. Je te répondrai vraiment quand l'appli parlera au serveur (contexte : \(contexte))."))
            if !ouvert { aQuelqueChoseADire = true }
        }
    }
}
