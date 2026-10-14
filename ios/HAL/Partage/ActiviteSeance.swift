import ActivityKit
import AppIntents
import Foundation

/// La Live Activity d'une séance de musculation (IOS-3, SAI-18) : l'exercice, la
/// série et le repos, sur l'écran verrouillé et dans la Dynamic Island.
struct AttributsSeance: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var exercice: String
        /// La série qui vient, de 1 à `seriesPrevues`.
        var serie: Int
        var seriesPrevues: Int?
        var seriesFaites: Int
        var debutDuRepos: Date?
        var finDuRepos: Date?

        /// Le repos en cours, du début à la fin. Une plage, jamais à l'envers : un
        /// widget peut se dessiner après la fin du repos.
        var repos: ClosedRange<Date>? {
            guard let finDuRepos else { return nil }
            return min(debutDuRepos ?? finDuRepos, finDuRepos)...finDuRepos
        }

        var serieEnClair: String {
            seriesPrevues.map { "Série \(min(serie, $0)) sur \($0)" } ?? "Série \(serie)"
        }
    }

    var titre: String
    var debut: Date
}

/// Ce que le bouton de la Live Activity appelle dans l'appli. L'appli le pose au
/// lancement ; dans le widget, il reste vide.
@MainActor
enum PontSeance {
    static var passerLeRepos: (() -> Void)?
}

/// « Passer » dans la Dynamic Island déployée : le repos s'arrête, la série suivante attend.
struct PasserLeRepos: LiveActivityIntent {
    static let title: LocalizedStringResource = "Passer le repos"
    static let description = IntentDescription("Arrête le repos en cours de la séance.")

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { PontSeance.passerLeRepos?() }
        return .result()
    }
}
