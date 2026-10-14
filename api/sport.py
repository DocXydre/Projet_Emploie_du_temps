"""Organiser son sport : trois semaines, des propositions, et ses propres choix.

Le lundi matin, on ouvre une semaine, on voit ce qui est choisi et ce qui est
seulement réservé, et on choisit parmi cinq propositions au plus. Ce qu'on
choisit souvent devient une habitude, reproposée en tête quand elle tient dans
l'emploi du temps (SPT-18 à SPT-27).

Tout ce que le bot montre pour le sport est construit ici sous forme d'écrans :
un texte et des rangées de boutons. `bot.py` ne fait que les afficher, ce qui
permet de tester tout le parcours sans parler à Telegram.

Les boutons portent « sp:<action>:<arguments> », arguments séparés par « _ ».
Telegram limite ces données à 64 octets : on y met des identifiants et des
dates compactes, jamais de libellés.
"""

from __future__ import annotations

import logging
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

from api.base import executer, lister, un_seul
from api.config import configuration
from api.ecran import Ecran

LOG = logging.getLogger(__name__)

# Autant de semaines ouvertes, la semaine en cours comprise (SPT-18).
SEMAINES = 3

# Au-delà, une liste d'heures ne se lit plus sur un téléphone.
HEURES_MAX = 12

JOURS_COURTS = ("lun", "mar", "mer", "jeu", "ven", "sam", "dim")
JOURS_LONGS = ("lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche")

# Qui a choisi quoi, pour les habitudes : une lettre dans les données de rappel,
# le mot en base.
ORIGINES = {"p": "proposition", "h": "habitude", "m": "modifiee", "c": "manuelle"}


# `Ecran` vient de api/ecran.py : les calendriers s'en servent aussi. Le nom
# reste importable ici, où tous les écrans du sport le nomment.
__all__ = ["Ecran"]


# ---------------------------------------------------------------------------
# Horaires des lieux
# ---------------------------------------------------------------------------

def rafraichir_horaires(code: str | None = None) -> list[dict]:
    """Relève les créneaux publiés et remplace ceux qu'on avait.

    Un lieu par ligne de bilan. Un relevé qui échoue ou qui ne ramène rien
    laisse les horaires en place et le dit : mieux vaut des horaires d'hier
    qu'un planning vide, et c'est exactement l'erreur qui avait effacé deux
    semaines de services (SPT-15).
    """
    from psycopg.types.json import Json

    from api.collecteurs import suaps

    lieux = lister(
        "SELECT code, libelle, url_horaires, configuration FROM v_lieu_a_relever "
        " WHERE (%(c)s::VARCHAR IS NULL OR code = %(c)s) ORDER BY code",
        {"c": code},
    )

    bilans = []
    for lieu in lieux:
        ligne = {"lieu": lieu["code"]}
        try:
            releve = suaps.relever(lieu["url_horaires"], lieu["configuration"] or {})
        except Exception as erreur:  # noqa: BLE001 - une page injoignable est un cas
            ligne |= {"etat": "injoignable", "detail": f"{type(erreur).__name__}: {erreur}"}
            LOG.warning("Horaires %s : %s", lieu["code"], erreur)
            bilans.append(ligne)
            continue

        creneaux = [{"jour": c.jour, "debut": c.debut, "fin": c.fin}
                    for c in releve["creneaux"]]
        try:
            un_seul("SELECT remplacer_ouvertures(%(c)s, %(j)s) AS n",
                    {"c": lieu["code"], "j": Json(creneaux)})
        except Exception as erreur:  # noqa: BLE001 - refus volontaire sur relevé vide
            ligne |= {"etat": "conservés", "detail": str(erreur).strip(),
                      "rejets": releve["rejets"]}
            LOG.warning("Horaires %s conservés : %s", lieu["code"], erreur)
            bilans.append(ligne)
            continue

        ligne |= {"etat": "à jour", "creneaux": len(creneaux),
                  "lues": releve["lues"], "rejets": releve["rejets"]}
        LOG.info("Horaires %s : %s créneau(x)", lieu["code"], len(creneaux))
        bilans.append(ligne)

    return bilans


def horaires(code: str = "PISCINE_SUAPS") -> list[dict]:
    """Les créneaux connus d'un lieu, pour les montrer."""
    return lister(
        """
        SELECT o.jour_semaine, o.heure_debut, o.heure_fin, l.horaires_releves_le
          FROM ouverture o JOIN lieu_sport l USING (id_lieu)
         WHERE l.code = %(c)s
         ORDER BY o.jour_semaine, o.heure_debut
        """,
        {"c": code},
    )


def lieu_par_nom(nom: str) -> dict | None:
    """Retrouve un lieu sur un fragment de son code ou de son libellé.

    « salle », « piscine », « course » suffisent. La casse est ignorée ; les
    accents ne le sont pas, mais aucun des trois fragments utiles n'en porte.
    """
    nom = (nom or "").strip()
    if not nom:
        return None

    return un_seul(
        """
        SELECT id_lieu, code, libelle FROM lieu_sport
         WHERE code ILIKE '%%' || %(n)s || '%%'
            OR libelle ILIKE '%%' || %(n)s || '%%'
         ORDER BY length(libelle)
         LIMIT 1
        """,
        {"n": nom},
    )


# ---------------------------------------------------------------------------
# Dates, et leur écriture compacte dans les boutons
# ---------------------------------------------------------------------------

def _fuseau() -> ZoneInfo:
    return ZoneInfo(configuration().fuseau)


def aujourd_hui() -> date:
    return datetime.now(_fuseau()).date()


def lundi_de(jour: date) -> date:
    return jour - timedelta(days=jour.weekday())


def _code_jour(jour: date) -> str:
    return jour.strftime("%Y%m%d")


def _jour(code: str) -> date:
    return datetime.strptime(code, "%Y%m%d").date()


def _code_instant(instant: datetime) -> str:
    return instant.astimezone(_fuseau()).strftime("%Y%m%d%H%M")


def _instant(code: str) -> datetime:
    return datetime.strptime(code, "%Y%m%d%H%M").replace(tzinfo=_fuseau())


def _local(instant: datetime) -> datetime:
    return instant.astimezone(_fuseau())


def _date(jour: date) -> str:
    """« mar 22/09 »"""
    return f"{JOURS_COURTS[jour.weekday()]} {jour:%d/%m}"


def _date_longue(jour: date) -> str:
    """« mardi 22/09 »"""
    return f"{JOURS_LONGS[jour.weekday()]} {jour:%d/%m}"


def _h(instant: datetime) -> str:
    return _local(instant).strftime("%Hh%M")


def _marque(origine: str) -> str:
    """Ce qu'un bouton dit d'une proposition tirée d'une habitude.

    SPT-22 : le pourcentage classe les propositions, il ne s'affiche pas.
    « 50 % » sur un bouton demandait de deviner 50 % de quoi, et ne voulait
    rien dire les premières semaines, faute d'historique.
    """
    return " · habituel" if origine == "habitude" else ""


def _court(libelle: str) -> str:
    """« Piscine du SUAPS » devient « Piscine » : un bouton a peu de place."""
    return (libelle or "").split(" ")[0]


# ---------------------------------------------------------------------------
# Lectures
# ---------------------------------------------------------------------------

def minimum(id_utilisateur: int) -> int:
    """La fréquence de cette personne : la sienne, sinon celle de la tâche.

    SPT-28 : trois séances par semaine pour l'un peut n'avoir aucun sens pour
    l'autre, et zéro est une réponse valable.
    """
    ligne = un_seul("SELECT minimum_sport(%(u)s) AS n", {"u": id_utilisateur})
    return (ligne or {}).get("n", 3)


def regler_minimum(id_utilisateur: int, valeur: int) -> int:
    """Change la fréquence et réorganise les trois semaines aussitôt."""
    ligne = un_seul("SELECT regler_minimum_sport(%(u)s, %(n)s) AS n",
                    {"u": id_utilisateur, "n": valeur})
    return (ligne or {}).get("n", valeur)


def lieux() -> list[dict]:
    return lister(
        """
        SELECT l.id_lieu, l.code, l.libelle, tl.rang
          FROM tache_lieu tl
          JOIN tache t      ON t.id_tache = tl.id_tache
          JOIN lieu_sport l ON l.id_lieu = tl.id_lieu
         WHERE t.code = 'SPORT'
         ORDER BY tl.rang, l.id_lieu
        """
    )


def _lieu(id_lieu: int) -> dict | None:
    return un_seul("SELECT id_lieu, code, libelle, duree_minutes FROM lieu_sport "
                   " WHERE id_lieu = %(l)s", {"l": id_lieu})


def seances_choisies(id_utilisateur: int, lundi: date | None = None) -> list[dict]:
    """Séances choisies à venir : d'une semaine, ou de toutes."""
    return lister(
        """
        SELECT o.id_occurrence, o.id_lieu, l.libelle AS lieu,
               COALESCE(o.debut_seance, lower(o.creneau)) AS debut,
               lower(o.creneau) AS bloc_debut, upper(o.creneau) AS bloc_fin,
               o.statut
          FROM occurrence o
          JOIN tache t           ON t.id_tache = o.id_tache
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_utilisateur = %(u)s
           AND t.code = 'SPORT'
           AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee')
           AND upper(o.creneau) > now()
           AND (%(l)s::DATE IS NULL
                OR jour_de(COALESCE(o.debut_seance, lower(o.creneau)))
                   BETWEEN %(l)s::DATE AND %(l)s::DATE + 6)
         ORDER BY 4
        """,
        {"u": id_utilisateur, "l": lundi},
    )


def nombre_choisies(id_utilisateur: int, lundi: date) -> int:
    """Ce qui compte pour le minimum : les séances faites aussi."""
    ligne = un_seul(
        """
        SELECT count(*) AS n
          FROM occurrence o JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = %(u)s
           AND t.code = 'SPORT'
           AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee', 'faite')
           AND jour_de(COALESCE(o.debut_seance, lower(o.creneau)))
               BETWEEN %(l)s::DATE AND %(l)s::DATE + 6
        """,
        {"u": id_utilisateur, "l": lundi},
    )
    return (ligne or {}).get("n", 0)


def reservations(id_utilisateur: int, lundi: date) -> list[dict]:
    """Les séances à déterminer encore à venir de la semaine."""
    return lister(
        """
        SELECT o.id_occurrence, o.id_lieu, l.libelle AS lieu,
               o.debut_seance AS debut,
               lower(o.creneau) AS bloc_debut, upper(o.creneau) AS bloc_fin
          FROM occurrence o
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_utilisateur = %(u)s
           AND o.origine = 'quota'
           AND o.statut IN ('planifiee', 'notifiee')
           AND lower(o.creneau) > now()
           AND jour_de(o.debut_seance) BETWEEN %(l)s::DATE AND %(l)s::DATE + 6
         ORDER BY o.debut_seance
        """,
        {"u": id_utilisateur, "l": lundi},
    )


def propositions(id_utilisateur: int, lundi: date, ignorer: int | None = None,
                 jours_pris: list[date] | None = None, maximum: int = 5) -> list[dict]:
    return lister(
        """
        SELECT p.rang, p.jour, p.id_lieu, l.libelle AS lieu, p.debut,
               lower(p.bloc) AS bloc_debut, upper(p.bloc) AS bloc_fin,
               p.origine, p.pourcentage,
               seance_possible_a_deux(%(u)s, p.id_lieu, p.debut) AS a_deux
          FROM propositions_sport(%(u)s, %(l)s, %(i)s, %(j)s::DATE[], %(m)s) p
          JOIN lieu_sport l ON l.id_lieu = p.id_lieu
         -- SPT-30 : les créneaux où l'autre est libre passent devant.
         ORDER BY seance_possible_a_deux(%(u)s, p.id_lieu, p.debut) DESC, p.rang
        """,
        {"u": id_utilisateur, "l": lundi, "i": ignorer, "j": jours_pris or [],
         "m": maximum},
    )


def possible_a_deux(id_utilisateur: int, id_lieu: int, debut: datetime) -> bool:
    """SPT-30 : quelqu'un d'autre tient-il ce créneau, au même endroit ?"""
    ligne = un_seul(
        "SELECT seance_possible_a_deux(%(u)s, %(l)s, %(d)s) AS oui",
        {"u": id_utilisateur, "l": id_lieu, "d": debut},
    )
    return bool(ligne and ligne["oui"])


def autres_sportifs(id_utilisateur: int) -> list[dict]:
    return lister(
        "SELECT u.id_utilisateur, u.nom FROM partenaires_sport(%(u)s) p "
        "  JOIN utilisateur u ON u.id_utilisateur = p ORDER BY u.nom",
        {"u": id_utilisateur},
    )


def inviter(occ: int) -> int:
    """SPT-31 : propose la séance aux autres, s'ils sont libres à ce moment."""
    ligne = un_seul("SELECT inviter_a_la_seance(%(o)s) AS n", {"o": occ})
    return (ligne or {}).get("n", 0)


def compagnons(occ: int) -> list[dict]:
    return lister("SELECT * FROM compagnons_de_seance(%(o)s)", {"o": occ})


def repondre_a_l_invitation(id_utilisateur: int, invitation: int,
                            vient: bool) -> int | None:
    ligne = un_seul(
        "SELECT repondre_invitation(%(i)s, %(u)s, %(v)s) AS id_occurrence",
        {"i": invitation, "u": id_utilisateur, "v": vient},
    )
    return (ligne or {}).get("id_occurrence")


def invitation(id_utilisateur: int, invitation_id: int) -> dict | None:
    return un_seul(
        """
        SELECT inv.id_invitation, inv.statut, u.nom AS qui, l.libelle AS lieu,
               o.debut_seance AS debut
          FROM invitation_sport inv
          JOIN occurrence o ON o.id_occurrence = inv.id_occurrence
          JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE inv.id_invitation = %(i)s AND inv.id_invite = %(u)s
        """,
        {"i": invitation_id, "u": id_utilisateur},
    )


def heures_possibles(id_utilisateur: int, id_lieu: int, jour: date,
                     ignorer: int | None = None) -> list[datetime]:
    return [ligne["h"] for ligne in lister(
        "SELECT h FROM heures_seance_sport(%(u)s, %(l)s, %(j)s, %(i)s) h",
        {"u": id_utilisateur, "l": id_lieu, "j": jour, "i": ignorer})]


def meilleure_heure(id_utilisateur: int, id_lieu: int, jour: date,
                    ignorer: int | None = None) -> datetime | None:
    ligne = un_seul("SELECT meilleure_heure_sport(%(u)s, %(l)s, %(j)s, %(i)s) AS h",
                    {"u": id_utilisateur, "l": id_lieu, "j": jour, "i": ignorer})
    return (ligne or {}).get("h")


def obstacle(id_utilisateur: int, id_lieu: int, debut: datetime,
             ignorer: int | None = None, strict: bool = True) -> str | None:
    ligne = un_seul("SELECT obstacle_seance(%(u)s, %(l)s, %(d)s, %(i)s, %(s)s) AS r",
                    {"u": id_utilisateur, "l": id_lieu, "d": debut, "i": ignorer,
                     "s": strict})
    return (ligne or {}).get("r")


def _bloc(id_utilisateur: int, id_lieu: int, debut: datetime) -> tuple[datetime, datetime]:
    ligne = un_seul("SELECT lower(b) AS debut, upper(b) AS fin "
                    "  FROM bloc_de_seance(%(u)s, %(l)s, %(d)s) b",
                    {"u": id_utilisateur, "l": id_lieu, "d": debut})
    return ligne["debut"], ligne["fin"]


def _seance(id_utilisateur: int, id_occurrence: int) -> dict | None:
    return un_seul(
        """
        SELECT o.id_occurrence, o.id_lieu, l.libelle AS lieu, o.statut,
               COALESCE(o.debut_seance, lower(o.creneau)) AS debut
          FROM occurrence o
          JOIN tache t           ON t.id_tache = o.id_tache
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_occurrence = %(o)s
           AND o.id_utilisateur = %(u)s
           AND t.code = 'SPORT'
           AND o.origine <> 'quota'
        """,
        {"o": id_occurrence, "u": id_utilisateur},
    )


def _raison(erreur: Exception) -> str:
    diag = getattr(erreur, "diag", None)
    if diag is not None and diag.message_primary:
        return diag.message_primary
    LOG.exception("Action de sport impossible")
    return "Impossible pour l'instant."


# ---------------------------------------------------------------------------
# Écrans
# ---------------------------------------------------------------------------

def _titre_semaine(lundi: date) -> str:
    ecart = (lundi - lundi_de(aujourd_hui())).days // 7
    if ecart <= 0:
        return f"Cette semaine ({lundi:%d/%m})"
    if ecart == 1:
        return f"Semaine prochaine ({lundi:%d/%m})"
    return f"Semaine du {lundi:%d/%m}"


def semaines_ouvertes() -> list[date]:
    lundi = lundi_de(aujourd_hui())
    return [lundi + timedelta(weeks=n) for n in range(SEMAINES)]


def ecran_semaines(id_utilisateur: int) -> Ecran:
    """SPT-18 : la semaine en cours et les deux suivantes, toujours.

    C'est l'entrée de /sport comme de /organiser : on voit d'un coup d'œil ce
    qui est choisi dans chaque semaine, puis on en ouvre une pour choisir,
    modifier ou supprimer.
    """
    mini = minimum(id_utilisateur)
    entete = (f"(au moins {mini} séances par semaine)" if mini
              else "(aucune séance organisée : fréquence à zéro)")
    lignes = [f"<b>Tes trois semaines de sport</b> {entete}"]
    boutons = []
    for lundi in semaines_ouvertes():
        n = nombre_choisies(id_utilisateur, lundi)
        a_determiner = len(reservations(id_utilisateur, lundi))
        lignes += ["", f"{_titre_semaine(lundi)} : {n}/{mini}"
                   + (f", {a_determiner} à déterminer" if a_determiner else "")]
        for s in seances_choisies(id_utilisateur, lundi):
            lignes.append(f"• {_date(_local(s['debut']).date())} · {s['lieu']} {_h(s['debut'])}")

        marque = "✅ " if n >= mini else ""
        boutons.append([(f"{marque}{_titre_semaine(lundi)} · {n}/{mini}",
                         f"sp:sem:{_code_jour(lundi)}")])

    lignes += ["", "Ouvre une semaine pour choisir, modifier ou supprimer tes séances."]
    boutons.append([("⚙ Fréquence", "sp:fq:")])
    return Ecran("\n".join(lignes), boutons)


def ecran_frequence(id_utilisateur: int) -> Ecran:
    """Combien de séances par semaine, de zéro à cinq (SPT-28)."""
    actuel = minimum(id_utilisateur)
    lignes = [
        "<b>Ta fréquence de sport</b>",
        "",
        f"Actuellement : {actuel} séance(s) par semaine.",
        "",
        "C'est le nombre de séances que le système tient dans chaque semaine. "
        "Ce qui manque est réservé « à déterminer » sur tes meilleurs créneaux. "
        "À zéro, plus rien n'est réservé et le lundi ne te relance plus, mais "
        "tu gardes tes écrans et tu peux poser une séance quand tu veux.",
    ]
    rangee, boutons = [], []
    for n in range(6):
        marque = "🔘 " if n == actuel else ""
        rangee.append((f"{marque}{n}", f"sp:fq:{n}"))
        if len(rangee) == 3:
            boutons.append(rangee)
            rangee = []
    if rangee:
        boutons.append(rangee)
    boutons.append([("↩ Mes semaines", "sp:w:0")])
    return Ecran("\n".join(lignes), boutons)


def changer_frequence(id_utilisateur: int, valeur: int) -> Ecran:
    try:
        applique = regler_minimum(id_utilisateur, valeur)
    except Exception as erreur:  # noqa: BLE001 - la base écrit déjà son refus
        return Ecran(_raison(erreur) + ".", [[("↩ Mes semaines", "sp:w:0")]])

    ecran = ecran_semaines(id_utilisateur)
    entete = (f"Fréquence réglée sur {applique} séance(s) par semaine."
              if applique else "Fréquence à zéro : plus rien ne sera réservé.")
    return Ecran(entete + "\n\n" + ecran.texte, ecran.boutons)


def ecran_semaine(id_utilisateur: int, lundi: date, entete: str = "") -> Ecran:
    """Ce qui est choisi, ce qui est réservé, et ce qu'on propose (SPT-20)."""
    mini = minimum(id_utilisateur)
    choisies = seances_choisies(id_utilisateur, lundi)
    reservees = reservations(id_utilisateur, lundi)
    n = nombre_choisies(id_utilisateur, lundi)

    lignes = []
    if entete:
        lignes += [entete, ""]
    lignes.append(f"<b>Semaine du {_date(lundi)} au {_date(lundi + timedelta(days=6))}</b>")
    lignes.append(f"Séances choisies : {n} (minimum {mini})")
    for s in choisies:
        lignes.append(f"• {_date(_local(s['debut']).date())} · {s['lieu']} {_h(s['debut'])}")

    if reservees:
        lignes += ["", "À déterminer, réservé dans ton calendrier :"]
        for r in reservees:
            lignes.append(f"• {_date(_local(r['debut']).date())} vers {_h(r['debut'])}")

    boutons: list[list[tuple[str, str]]] = []
    for s in choisies:
        boutons.append([(f"✅ {_date(_local(s['debut']).date())} · "
                         f"{_court(s['lieu'])} {_h(s['debut'])}",
                         f"sp:g:{s['id_occurrence']}")])

    # Les réservations d'abord : ce sont les meilleures propositions, et les
    # choisir libère le calendrier. Puis le reste, jusqu'à cinq en tout.
    proposees = 0
    for r in reservees:
        if r["id_lieu"] is None:
            continue
        boutons.append([(f"📌 {_date(_local(r['debut']).date())} · "
                         f"{_court(r['lieu'])} {_h(r['debut'])}",
                         f"sp:p:{r['id_lieu']}_{_code_instant(r['debut'])}_0_p")])
        proposees += 1

    if proposees < 5:
        jours_reserves = [_local(r["debut"]).date() for r in reservees]
        for p in propositions(id_utilisateur, lundi, jours_pris=jours_reserves,
                              maximum=5 - proposees):
            marque = _marque(p["origine"]) + (" · à deux" if p["a_deux"] else "")
            origine = "h" if p["origine"] == "habitude" else "p"
            duo = "1" if p["a_deux"] else "0"
            boutons.append([(f"{_date(p['jour'])} · {_court(p['lieu'])} "
                             f"{_h(p['debut'])}{marque}",
                             f"sp:p:{p['id_lieu']}_{_code_instant(p['debut'])}"
                             f"_0_{origine}_{duo}")])
            proposees += 1

    lignes.append("")
    if proposees:
        lignes.append("Choisis une proposition, ou crée ta séance. "
                      "📌 : déjà réservé en attendant ton choix.")
    else:
        lignes.append("Plus rien ne tient cette semaine d'après l'emploi du temps. "
                      "Tu peux quand même créer ta séance.")

    boutons.append([("➕ Créer ma séance", f"sp:c:{_code_jour(lundi)}")])
    boutons.append([("↩ Semaines", "sp:w:0")])
    return Ecran("\n".join(lignes), boutons)


def _retour(lundi: date, occ: int) -> tuple[str, str]:
    """Le bouton de retour : la séance qu'on modifie, ou sa semaine."""
    if occ:
        return ("↩ Retour", f"sp:g:{occ}")
    return ("↩ Semaine", f"sp:sem:{_code_jour(lundi)}")


def ecran_confirmation(id_utilisateur: int, id_lieu: int, debut: datetime,
                       occ: int = 0, origine: str = "p", duo: str = "0") -> Ecran:
    """SPT-21 : avant de valider, on peut changer l'heure, le sport ou le jour.

    SPT-30 : quand l'autre est libre au même moment, on le dit ici, et valider
    lui posera la question. Il reste libre de ne pas venir.
    """
    lieu = _lieu(id_lieu)
    if lieu is None:
        return Ecran("Sport inconnu.", [[("↩ Semaines", "sp:w:0")]])

    jour = _local(debut).date()
    lundi = lundi_de(jour)
    duree = lieu["duree_minutes"] or 60
    bloc_debut, bloc_fin = _bloc(id_utilisateur, id_lieu, debut)

    lignes = [f"<b>{lieu['libelle']}</b>",
              f"{_date_longue(jour)} à {_h(debut)}, pendant {duree} min",
              f"Réservé de {_h(bloc_debut)} à {_h(bloc_fin)}, trajet et marges compris."]

    # Ce qui interdit le choix (un cours, un service), et ce qui le déconseille
    # seulement (lieu fermé, bloc qui déborde) : on sait parfois mieux.
    bloquant = obstacle(id_utilisateur, id_lieu, debut, occ or None, strict=False)
    avertissement = None if bloquant else obstacle(id_utilisateur, id_lieu, debut,
                                                   occ or None, strict=True)

    a_deux = duo == "1" and not occ and possible_a_deux(id_utilisateur, id_lieu, debut)
    if a_deux:
        autres = " et ".join(c["nom"] for c in autres_sportifs(id_utilisateur))
        lignes += ["", f"{autres} est libre à ce moment : en validant, "
                       f"je lui propose de venir."]

    code = f"{id_lieu}_{_code_instant(debut)}_{occ}_{origine}_{'1' if a_deux else '0'}"
    suite = "c" if origine == "c" else "m"
    changer = [("🕐 Changer l'heure", f"sp:h:{id_lieu}_{_code_jour(jour)}_{occ}_{suite}"),
               ("🔁 Changer le sport", f"sp:s:{_code_instant(debut)}_{occ}_{suite}")]

    boutons: list[list[tuple[str, str]]] = []
    if bloquant:
        lignes += ["", f"Impossible : {bloquant}."]
    else:
        if avertissement:
            lignes += ["", f"Attention : {avertissement}."]
        boutons.append([("✅ Valider à deux" if a_deux else "✅ Valider",
                         f"sp:ok:{code}")])

    boutons.append(changer)
    boutons.append([("📅 Changer le jour", f"sp:j:{id_lieu}_{_code_jour(lundi)}_{occ}_{suite}"),
                    _retour(lundi, occ)])
    return Ecran("\n".join(lignes), boutons)


def _eclaircir(heures: list[datetime]) -> list[datetime]:
    """Garde une liste d'heures lisible : les demi-heures, puis les heures."""
    for garder in (None, (0, 30), (0,)):
        retenues = [h for h in heures if garder is None or _local(h).minute in garder]
        if len(retenues) <= HEURES_MAX:
            return retenues
    pas = max(1, len(retenues) // HEURES_MAX + 1)
    return retenues[::pas][:HEURES_MAX]


def ecran_heures(id_utilisateur: int, id_lieu: int, jour: date,
                 occ: int = 0, origine: str = "m") -> Ecran:
    """SPT-24 : les heures qui tiennent, en boutons, plutôt qu'à écrire."""
    lieu = _lieu(id_lieu)
    lundi = lundi_de(jour)
    heures = _eclaircir(heures_possibles(id_utilisateur, id_lieu, jour, occ or None))

    lignes = [f"{lieu['libelle']}, {_date_longue(jour)} : à quelle heure ?"]
    boutons: list[list[tuple[str, str]]] = []
    rangee: list[tuple[str, str]] = []
    for h in heures:
        rangee.append((_h(h), f"sp:p:{id_lieu}_{_code_instant(h)}_{occ}_{origine}"))
        if len(rangee) == 4:
            boutons.append(rangee)
            rangee = []
    if rangee:
        boutons.append(rangee)

    if not heures:
        lignes += ["", "Rien ne tient entièrement ce jour-là, trajet et marges compris.",
                   f"Pour forcer une heure : /organiser {jour:%d/%m} 18h "
                   f"{_court(lieu['libelle']).lower()}"]

    boutons.append([("🔁 Autre sport", f"sp:s:{_code_jour(jour)}0000_{occ}_{origine}"),
                    ("📅 Autre jour", f"sp:j:{id_lieu}_{_code_jour(lundi)}_{occ}_{origine}")])
    boutons.append([_retour(lundi, occ)])
    return Ecran("\n".join(lignes), boutons)


def ecran_sports(id_utilisateur: int, reference: datetime, occ: int = 0,
                 origine: str = "m") -> Ecran:
    """Chaque sport ce jour-là : à la même heure s'il y tient, sinon au mieux."""
    jour = _local(reference).date()
    lundi = lundi_de(jour)
    boutons: list[list[tuple[str, str]]] = []
    for lieu in lieux():
        heure = None
        if _local(reference).hour or _local(reference).minute:
            if obstacle(id_utilisateur, lieu["id_lieu"], reference, occ or None) is None:
                heure = reference
        heure = heure or meilleure_heure(id_utilisateur, lieu["id_lieu"], jour, occ or None)
        if heure is None:
            boutons.append([(f"{lieu['libelle']} · rien de libre",
                             f"sp:h:{lieu['id_lieu']}_{_code_jour(jour)}_{occ}_{origine}")])
            continue
        boutons.append([(f"{lieu['libelle']} · {_h(heure)}",
                         f"sp:p:{lieu['id_lieu']}_{_code_instant(heure)}_{occ}_{origine}")])

    boutons.append([_retour(lundi, occ)])
    return Ecran(f"Quel sport le {_date_longue(jour)} ?", boutons)


def ecran_jours(id_utilisateur: int, id_lieu: int, lundi: date,
                occ: int = 0, origine: str = "m") -> Ecran:
    """Les jours restants de la semaine, pour un sport donné."""
    lieu = _lieu(id_lieu)
    boutons: list[list[tuple[str, str]]] = []
    jour = max(lundi, aujourd_hui())
    while jour <= lundi + timedelta(days=6):
        heure = meilleure_heure(id_utilisateur, id_lieu, jour, occ or None)
        etat = f" · dès {_h(heure)}" if heure else " · complet"
        boutons.append([(f"{_date(jour)}{etat}",
                         f"sp:h:{id_lieu}_{_code_jour(jour)}_{occ}_{origine}")])
        jour += timedelta(days=1)

    boutons.append([_retour(lundi, occ)])
    return Ecran(f"{lieu['libelle']} : quel jour ?", boutons)


def ecran_creation(lundi: date) -> Ecran:
    """Créer sa séance : le sport, puis le jour, puis l'heure."""
    boutons = [[(lieu["libelle"], f"sp:j:{lieu['id_lieu']}_{_code_jour(lundi)}_0_c")]
               for lieu in lieux()]
    boutons.append([("↩ Semaine", f"sp:sem:{_code_jour(lundi)}")])
    return Ecran("Quel sport ?", boutons)


def ecran_seance(id_utilisateur: int, occ: int) -> Ecran:
    seance = _seance(id_utilisateur, occ)
    if seance is None or seance["statut"] not in ("planifiee", "notifiee"):
        return Ecran("Cette séance n'existe plus.", [[("📅 Mes semaines", "sp:w:0")]])

    jour = _local(seance["debut"]).date()
    lignes = [f"<b>{seance['lieu']}</b>",
              f"{_date_longue(jour)} à {_h(seance['debut'])}"]

    # SPT-32 : qui a dit qu'il venait, qui a dit non, qui n'a pas répondu.
    for c in compagnons(occ):
        lignes.append({"acceptee": f"Avec {c['nom']}.",
                       "refusee": f"{c['nom']} ne vient pas.",
                       "attente": f"En attente de la réponse de {c['nom']}."}[c["statut"]])

    return Ecran(
        "\n".join(lignes),
        [[("✏️ Modifier", f"sp:m:{occ}"), ("🗑 Supprimer", f"sp:del:{occ}")],
         [("Ne rien faire", "sp:x:0")]])


def ecran_modifier(id_utilisateur: int, occ: int) -> Ecran:
    seance = _seance(id_utilisateur, occ)
    if seance is None or seance["statut"] not in ("planifiee", "notifiee"):
        return Ecran("Cette séance n'existe plus.", [[("📅 Mes semaines", "sp:w:0")]])

    jour = _local(seance["debut"]).date()
    lieu = seance["id_lieu"]
    return Ecran(
        f"{seance['lieu']}, {_date_longue(jour)} à {_h(seance['debut'])}.\n"
        "Que veux-tu changer ?",
        [[("🕐 L'heure", f"sp:h:{lieu}_{_code_jour(jour)}_{occ}_m"),
          ("🔁 Le sport", f"sp:s:{_code_instant(seance['debut'])}_{occ}_m")],
         [("📅 Le jour", f"sp:j:{lieu}_{_code_jour(lundi_de(jour))}_{occ}_m"),
          ("↩ Retour", f"sp:g:{occ}")]])


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

def choisir(id_utilisateur: int, id_lieu: int, debut: datetime,
            occ: int | None = None, origine: str = "proposition") -> int:
    """Crée la séance, ou modifie celle donnée. Lève l'erreur de la base."""
    ligne = un_seul(
        "SELECT choisir_seance_sport(%(u)s, %(l)s, %(d)s, %(o)s, %(g)s) AS id",
        {"u": id_utilisateur, "l": id_lieu, "d": debut, "o": occ or None, "g": origine},
    )
    _replacer()
    return ligne["id"]


def valider(id_utilisateur: int, id_lieu: int, debut: datetime,
            occ: int = 0, origine: str = "p", duo: str = "0") -> Ecran:
    try:
        nouvelle = choisir(id_utilisateur, id_lieu, debut, occ or None,
                           ORIGINES.get(origine, "proposition"))
    except psycopg.Error as erreur:
        # L'emploi du temps a pu changer depuis l'affichage : on remontre la
        # séance, avec ce qui bloque et de quoi la déplacer.
        ecran = ecran_confirmation(id_utilisateur, id_lieu, debut, occ, origine, duo)
        raison = _raison(erreur)
        if raison not in ecran.texte:
            ecran.texte = f"{raison}.\n\n{ecran.texte}"
        return ecran

    # SPT-31 : la séance est à moi, l'invitation part à l'autre. Sa réponse ne
    # changera rien à la mienne.
    invitees = inviter(nouvelle) if duo == "1" and not occ else 0

    lieu = _lieu(id_lieu)
    jour = _local(debut).date()
    verbe = "Modifiée" if occ else "C'est noté"
    entete = (f"{verbe} : {lieu['libelle']}, {_date_longue(jour)} à {_h(debut)}.")
    if invitees:
        autres = " et ".join(c["nom"] for c in autres_sportifs(id_utilisateur))
        entete += f"\nJ'ai demandé à {autres} s'il ou elle vient."
    return ecran_semaine(id_utilisateur, lundi_de(jour), entete=entete)


def repondre_invitation_ecran(id_utilisateur: int, invitation_id: int,
                              vient: bool) -> Ecran:
    """SPT-31 : « je viens » crée ma séance, « pas cette fois » ne fait rien."""
    details = invitation(id_utilisateur, invitation_id)
    if details is None:
        return Ecran("Cette invitation n'existe plus.", [[("📅 Mes semaines", "sp:w:0")]])

    try:
        repondre_a_l_invitation(id_utilisateur, invitation_id, vient)
    except psycopg.Error as erreur:
        return Ecran(_raison(erreur) + ".", [[("📅 Mes semaines", "sp:w:0")]])

    jour = _local(details["debut"]).date()
    if not vient:
        return Ecran(f"C'est noté, tu ne viens pas {_date_longue(jour)}. "
                     f"{details['qui']} y va quand même.",
                     [[("📅 Mes semaines", "sp:w:0")]])

    _replacer()
    return ecran_semaine(id_utilisateur, lundi_de(jour),
                         entete=f"C'est noté : {details['lieu']} avec {details['qui']}, "
                                f"{_date_longue(jour)} à {_h(details['debut'])}.")


def supprimer(id_utilisateur: int, occ: int) -> Ecran:
    try:
        ligne = un_seul("SELECT supprimer_seance_sport(%(u)s, %(o)s) AS jour",
                        {"u": id_utilisateur, "o": occ})
    except psycopg.Error as erreur:
        return Ecran(_raison(erreur) + ".", [[("📅 Mes semaines", "sp:w:0")]])
    _replacer()
    return ecran_semaine(id_utilisateur, lundi_de(ligne["jour"]),
                         entete=f"Séance du {_date_longue(ligne['jour'])} supprimée.")


def pas_faite(id_utilisateur: int, occ: int) -> Ecran:
    """SPT-25 : la séance est close, la semaine se complète ailleurs."""
    try:
        ligne = un_seul("SELECT seance_sport_pas_faite(%(u)s, %(o)s) AS jour",
                        {"u": id_utilisateur, "o": occ})
    except psycopg.Error as erreur:
        return Ecran(_raison(erreur) + ".")
    _replacer()

    lundi = lundi_de(ligne["jour"])
    restantes = reservations(id_utilisateur, lundi) if lundi == lundi_de(aujourd_hui()) else []
    texte = f"Noté, pas de sport le {_date_longue(ligne['jour'])}."
    if restantes:
        texte += "\n\nÀ déterminer cette semaine :\n" + "\n".join(
            f"• {_date(_local(r['debut']).date())} vers {_h(r['debut'])}" for r in restantes)
    return Ecran(texte, [[("📅 Organiser la semaine", f"sp:sem:{_code_jour(lundi)}")]])


def _replacer() -> None:
    """Ce que la séance a délogé se replace autour d'elle."""
    from api.ordonnanceur import placer
    try:
        placer()
    except Exception:  # noqa: BLE001 - le choix est fait, le placement suivra
        LOG.exception("Replacement après une séance de sport")


def depuis_texte(id_utilisateur: int, mots: list[str]) -> Ecran:
    """« /organiser 24/09 18h salle » : l'écran de confirmation de cette séance."""
    from api.conversation import lire_moment

    lu = lire_moment(mots)
    if lu is None:
        return Ecran("Je n'ai pas compris l'heure.\n\nÉcris par exemple "
                     "« /organiser 24/09 18h salle ». Le sport se devine sur un morceau "
                     "de son nom : salle, piscine, course.")
    debut, nom = lu
    lieu = lieu_par_nom(nom) if nom else (lieux() or [None])[0]
    if lieu is None:
        return Ecran(f"Sport inconnu : « {nom} ». Essaie salle, piscine ou course.")
    return ecran_confirmation(id_utilisateur, lieu["id_lieu"], debut, 0, "c")


# ---------------------------------------------------------------------------
# Aiguillage des boutons
# ---------------------------------------------------------------------------

def repondre(id_utilisateur: int, action: str, arguments: str) -> Ecran | None:
    """Traduit un bouton « sp:<action>:<arguments> » en écran. None : fermer."""
    a = arguments.split("_")

    if action == "w":
        return ecran_semaines(id_utilisateur)
    if action == "sem":
        return ecran_semaine(id_utilisateur, _jour(a[0]))
    if action == "p":
        return ecran_confirmation(id_utilisateur, int(a[0]), _instant(a[1]), int(a[2]),
                                  a[3], a[4] if len(a) > 4 else "0")
    if action == "ok":
        return valider(id_utilisateur, int(a[0]), _instant(a[1]), int(a[2]),
                       a[3], a[4] if len(a) > 4 else "0")
    if action == "inv":
        return repondre_invitation_ecran(id_utilisateur, int(a[0]), a[1] == "1")
    if action == "h":
        return ecran_heures(id_utilisateur, int(a[0]), _jour(a[1]), int(a[2]), a[3])
    if action == "s":
        return ecran_sports(id_utilisateur, _instant(a[0]), int(a[1]), a[2])
    if action == "j":
        return ecran_jours(id_utilisateur, int(a[0]), _jour(a[1]), int(a[2]), a[3])
    if action == "c":
        return ecran_creation(_jour(a[0]))
    if action == "g":
        return ecran_seance(id_utilisateur, int(a[0]))
    if action == "m":
        return ecran_modifier(id_utilisateur, int(a[0]))
    if action == "del":
        return supprimer(id_utilisateur, int(a[0]))
    if action == "pf":
        return pas_faite(id_utilisateur, int(a[0]))
    if action == "fq":
        if not a[0]:
            return ecran_frequence(id_utilisateur)
        return changer_frequence(id_utilisateur, int(a[0]))
    if action == "x":
        return None
    return Ecran("Ce bouton ne mène plus nulle part. Refais /organiser.")


# ---------------------------------------------------------------------------
# Ordonnanceur
# ---------------------------------------------------------------------------

def alerter_le_lundi() -> int:
    """SPT-27 : prévenir quand la semaine n'a pas son minimum de choisies."""
    ligne = executer("SELECT alerte_sport_du_lundi() AS n")
    return (ligne or {}).get("n", 0)


def constater_les_manquees() -> int:
    """SPT-25 : les séances à déterminer passées sans être choisies."""
    ligne = executer("SELECT seances_a_determiner_passees() AS n")
    return (ligne or {}).get("n", 0)
