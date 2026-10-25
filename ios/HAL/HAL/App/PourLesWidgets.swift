import Foundation
import WidgetKit

/// IOS-1, IOS-2 : après chaque chargement, l'appli garde pour ses widgets ce
/// qu'ils montrent, et leur demande de se redessiner. Les widgets n'appellent
/// jamais le serveur eux-mêmes.
extension Foyer {
    func publierPourLesWidgets() {
        guard connecte else { return }
        let debutDuJour = Calendar.current.startOfDay(for: .now)
        let finDuJour = Calendar.current.date(byAdding: .day, value: 1, to: debutDuJour) ?? .now
        let journee = evenementsDuJour
            .filter { !$0.journeeEntiere && $0.debut >= debutDuJour && $0.debut < finDuJour }
            .map { Instantane.Moment(debut: $0.debut, fin: $0.fin, titre: $0.titre, lieu: $0.lieu,
                                     categorie: $0.categorie.rawValue) }
        let aDeux = membres.count > 1
        let instantane = Instantane(
            misAJour: .now,
            sport: Instantane.Sport(faites: semaine.faites, prevues: semaine.prevues,
                                    prochaine: semaine.prochaine),
            // MON-8 : sans montre, pas de FC de repos sur l'écran d'accueil non plus.
            forme: Instantane.Forme(sommeilMinutes: forme.sommeilMinutes,
                                    fcRepos: aUneMontre ? forme.fcRepos : nil,
                                    pas: forme.pas,
                                    vfc: aUneMontre ? forme.vfc : nil),
            journee: journee,
            halADire: orbeADire,
            sansMontre: !aUneMontre,
            taches: tachesDuJour.map {
                Instantane.Tache(titre: $0.titre, faite: $0.faite, pourQui: aDeux ? $0.pourQui.nom : nil)
            },
            enRetard: tachesEnRetard.first.map {
                Instantane.EnRetard(titre: $0.titre,
                                    detail: $0.reports > 0 ? "reportée \($0.reports) fois" : Dates.depuis($0.fin),
                                    nombre: tachesEnRetard.count)
            },
            objectif: objectifEnCours.map {
                Instantane.Objectif(titre: $0.titre, joursRestants: $0.joursRestants, avancee: $0.avancee)
            },
            chat: Instantane.Chat(soins: chat.soins.prefix(3).map {
                Instantane.Chat.Soin(titre: $0.titre, quand: $0.quand)
            }),
            equilibre: Instantane.Equilibre(
                partDeMoi: partDeMoi, autre: autre?.nom,
                dureeMoi: EnFrancais.duree(minutes: minutesFaites[moi.id] ?? 0),
                dureeAutre: autre.map { EnFrancais.duree(minutes: minutesFaites[$0.id] ?? 0) }),
            frequence: aUneMontre ? frequenceDuJour.compactMap(\.valeur) : nil,
            weekend: weekendPourLesWidgets,
            train: prochainTrain.map { train in
                Instantane.Train(
                    trajet: "\(train.origine) → \(train.destination)", depart: train.depart,
                    detail: EnFrancais.duree(minutes: Int(train.arrivee.timeIntervalSince(train.depart) / 60))
                        + ((train.correspondances ?? 0) > 0 ? " · \(train.correspondances ?? 0) corresp." : ""))
            },
            semaine: maSemaine.filter { $0.journeeEntiere != true }.map {
                Instantane.Bloc(debut: $0.debut, fin: $0.fin, categorie: $0.famille.rawValue)
            },
            montre: seancesDeLaMontre.first.map { seance in
                let principal = seance.distanceM.flatMap { $0 > 0 ? EnFrancais.distance($0) : nil }
                    ?? seance.dureeSecondes.map { EnFrancais.duree(minutes: $0 / 60) } ?? "—"
                return Instantane.SeanceMontre(titre: Discipline.nom(seance.discipline), principal: principal,
                                               fcMoyenne: seance.fcMoyenne, debut: seance.debut)
            },
            derniereCourse: derniereCourse.map { course in
                Instantane.SeanceMontre(titre: "Dernière course · \(EnFrancais.jour(course.debut))",
                                        principal: course.distanceM.map(EnFrancais.distance) ?? "—",
                                        fcMoyenne: course.fcMoyenne, debut: course.debut,
                                        duree: course.dureeSecondes.map(EnFrancais.chrono),
                                        allure: course.allureSKm.map(EnFrancais.chrono))
            },
            linge: lingeAVenir.prefix(2).map { element in
                let jour = Calendar.current.isDateInToday(element.debut) ? "aujourd'hui" : EnFrancais.jour(element.debut)
                return Instantane.Ligne(titre: element.libelle,
                                        detail: element.journeeEntiere == true
                                            ? jour : "\(jour) · \(EnFrancais.heure(element.debut))")
            },
            bientot: bientot.prefix(8).map { element in
                Instantane.Ligne(titre: element.libelle, detail: EnFrancais.jourCourt(element.debut),
                                 qui: aDeux ? membre(numero: element.idUtilisateur).map { String($0.nom.prefix(1)) } : nil)
            })
        Partage.ecrire(instantane)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Le prochain week-end libre, ou à défaut le prochain train (WKD, TRJ).
    private var weekendPourLesWidgets: Instantane.Ligne? {
        if let proposition = propositions.first {
            return Instantane.Ligne(
                titre: "Week-end libre à \(proposition.lieu) ?",
                detail: "Du \(EnFrancais.jour(proposition.debut)) au \(EnFrancais.jour(proposition.fin))")
        }
        if let train = prochainTrain {
            return Instantane.Ligne(
                titre: "\(train.sens == "aller" ? "Départ" : "Retour") \(EnFrancais.jour(train.depart))",
                detail: "Train \(EnFrancais.heure(train.depart)) → \(train.destination)")
        }
        return nil
    }
}

/// IOS-1 : la séance en cours et le dernier mot de HAL ont chacun leur fichier,
/// écrit par qui les tient.
enum PourLesWidgets {
    static func publier(seance: SeanceEnWidget?) {
        Partage.ecrire(seance, dans: "seance.json")
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.docxydre.hal.seance-en-cours")
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.docxydre.hal.seance-libre")
    }

    static func publier(motDeHAL texte: String) {
        let ancien: MotDeHAL? = Partage.lire("hal.json")
        guard ancien?.texte != texte else { return }
        Partage.ecrire(MotDeHAL(texte: texte), dans: "hal.json")
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.docxydre.hal.hal")
    }
}
