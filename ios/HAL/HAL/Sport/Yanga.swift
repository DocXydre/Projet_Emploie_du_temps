import SwiftUI
import UserNotifications

/// SAI-21 : la gourde Yanga Sport du club. La machine ne la recharge qu'une
/// fois toutes les 20 minutes. L'heure de la dernière recharge reste sur le
/// téléphone : elle ne regarde que lui, et le serveur n'en sait rien.
enum Yanga {
    /// Le délai de la machine entre deux recharges.
    static let attente: TimeInterval = 20 * 60
    static let cleActive = "yanga.active"
    static let cleRecharge = "yanga.derniere_recharge"
    private static let notification = "yanga"

    /// Notée au retour de la machine. Une notification dit quand la suivante est
    /// possible, si la séance dure encore.
    static func recharger() {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: cleRecharge)
        let contenu = UNMutableNotificationContent()
        contenu.title = "Yanga"
        contenu.body = "Ta gourde peut se recharger."
        contenu.sound = .default
        let centre = UNUserNotificationCenter.current()
        centre.removePendingNotificationRequests(withIdentifiers: [notification])
        centre.add(UNNotificationRequest(
            identifier: notification, content: contenu,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: attente, repeats: false)))
    }

    /// « Elle est déjà possible » : on oublie la dernière recharge.
    static func oublier() {
        UserDefaults.standard.removeObject(forKey: cleRecharge)
        oublierLaNotification()
    }

    /// La séance finie, la notification n'a plus de raison de sonner.
    static func oublierLaNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notification])
    }
}

/// SAI-21 : la bulle de la séance en cours (3.5) et du repos (3.7). Prête, la
/// toucher dit qu'on vient de recharger ; sinon elle compte les minutes qui restent.
struct BulleYanga: View {
    @AppStorage(Yanga.cleActive) private var active = true
    @AppStorage(Yanga.cleRecharge) private var recharge: Double = 0

    var body: some View {
        if active {
            TimelineView(.periodic(from: .now, by: 1)) { contexte in
                let reste = recharge == 0 ? 0
                    : max(0, Date(timeIntervalSince1970: recharge).addingTimeInterval(Yanga.attente)
                        .timeIntervalSince(contexte.date))
                Group {
                    if reste == 0 {
                        Menu {
                            Button("Ne plus afficher", systemImage: "eye.slash") { active = false }
                        } label: {
                            bulle(reste: 0)
                        } primaryAction: {
                            Yanga.recharger()
                        }
                        .accessibilityLabel("Gourde Yanga : recharge possible")
                        .accessibilityHint("Touche quand tu as rechargé")
                    } else {
                        Menu {
                            Button("J'ai rechargé à l'instant", systemImage: "arrow.clockwise") { Yanga.recharger() }
                            Button("Elle est déjà possible", systemImage: "checkmark") { Yanga.oublier() }
                            Button("Ne plus afficher", systemImage: "eye.slash") { active = false }
                        } label: {
                            bulle(reste: reste)
                        }
                        .accessibilityLabel("Gourde Yanga : prochaine recharge \(Self.dans(reste))")
                    }
                }
                .sensoryFeedback(.success, trigger: reste == 0) { _, prete in prete }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: recharge)
        }
    }

    private func bulle(reste: TimeInterval) -> some View {
        let prete = reste == 0
        return HStack(spacing: 8) {
            ZStack {
                if prete {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.texteSurAccent)
                        .frame(width: 24, height: 24)
                        .background(Categorie.sport.couleur, in: Circle())
                } else {
                    Anneau(valeur: 1 - reste / Yanga.attente, couleur: Categorie.sport.couleur, epaisseur: 3)
                        .frame(width: 20, height: 20)
                    Image(systemName: "drop.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.texteSecondaire)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(prete ? "Yanga · recharge possible" : "Yanga \(Self.dans(reste))")
                    .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                    .monospacedDigit()
                Text(prete ? "Touche quand c'est fait" : "Prochaine recharge")
                    .texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 6)
        .frame(minHeight: 44)
        .verreControle(Capsule(), teinte: prete ? Categorie.sport.couleur.opacity(0.35) : nil)
        .animation(.smooth(duration: 0.3), value: prete)
    }

    /// « dans 12 min », puis « dans 45 s » pour la dernière minute.
    static func dans(_ reste: TimeInterval) -> String {
        let secondes = Int(reste.rounded(.up))
        return secondes < 60 ? "dans \(secondes) s" : "dans \(Int((reste / 60).rounded(.up))) min"
    }
}
