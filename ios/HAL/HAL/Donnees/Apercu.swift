import Foundation

/// Des données fictives pour faire tourner l'appli sans serveur. Les noms sont
/// inventés : le dépôt est public.
struct Apercu {
    let moi = Membre(id: 1, nom: "Alex", estAdministrateur: true)
    let autre: Membre? = Membre(id: 2, nom: "Sam", estAdministrateur: false)

    var evenements: [Evenement] {
        [
            Evenement(debut: heure(12, 45), fin: heure(13, 15), titre: "Course à pied", lieu: "5 km", categorie: .sport),
            Evenement(debut: heure(15, 30), fin: heure(17, 30), titre: "TD Algorithmique", lieu: "Salle 223", categorie: .cours),
            Evenement(debut: heure(19, 0), titre: "Laver la fontaine du chat", categorie: .chat),
            Evenement(debut: heure(21, 0), titre: "Lessive (draps)", categorie: .linge),
        ]
    }

    var taches: [Tache] {
        let sam = autre ?? moi
        return [
            Tache(id: 101, titre: "Litière", pourQui: moi, categorie: .chat, faite: false),
            Tache(id: 102, titre: "Lave-vaisselle", pourQui: sam, categorie: .menage, faite: true),
            Tache(id: 103, titre: "Aspirateur", pourQui: moi, categorie: .menage, faite: false, reports: 2),
            Tache(id: 104, titre: "Sortir les poubelles", pourQui: sam, categorie: .menage, faite: false),
        ]
    }

    let semaine = SemaineSport(faites: 2, prevues: 3, prochaine: "Jeu. 18:30 · Course")
    let forme = Forme(sommeilMinutes: 400, fcRepos: 55, vfc: 62, pas: 6840, tendanceFC: "+3 en 7 j")

    var frequence: [PointSerie] {
        (0..<48).map { pas in
            let date = Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(pas) * 1800)
            let base = 58 + 14 * sin(Double(pas) / 7)
            let effort = (pas == 25 || pas == 26) ? 70.0 : 0
            return PointSerie(date: date, valeur: date > .now ? nil : base + effort)
        }
    }

    let seance = SeanceDuJour(
        titre: "Haut du corps",
        heure: "18:30",
        duree: "1 h 10",
        exercices: ["Développé couché", "Tirage vertical", "Développé militaire", "Rowing haltère", "Curl biceps"],
        consigne: "Garde deux répétitions en réserve sur la dernière série."
    )

    let conflit = Conflit(
        id: 1,
        jour: "Jeu. 22 oct.",
        premier: .init(titre: "TD Analyse · groupe 2", horaire: "10:15 – 12:00", salle: "Salle 112"),
        second: .init(titre: "TP Administration PostgreSQL", horaire: "10:15 – 12:15", salle: "Salle 204")
    )

    let ajustement = Ajustement(id: 1, titre: "Alléger la course de samedi : 8 km", motif: "Ta VFC baisse depuis mardi.")
    let mesure = MesureDemandee(titre: "Pèse-toi ce matin", consigne: "À jeun, deux matins de suite.", jusquA: "jusqu'à jeudi")
    let objectif = Objectif(titre: "Semi-marathon", joursRestants: 47, avancee: 0.38)
    let chat = EtatChat(litiere: "aujourd'hui", eau: "demain", fontaine: "dans 4 jours")
    let dernierMotDeHAL = "Jambes ce soir ? Tu as bien dormi et ta dernière séance date de jeudi."

    private func heure(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: .now) ?? .now
    }
}
