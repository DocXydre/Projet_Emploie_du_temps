"""Organiser les séances de la semaine plutôt que de les imposer.

Le placement sait poser trois séances tout seul. Il ne sait pas qu'on préfère
courir le mardi et nager le jeudi — et c'est une décision qui se prend le lundi
matin, une fois l'emploi du temps connu, pas au fil de l'eau.

Ce module rassemble les possibilités et les présente. Le choix reste à faire,
et ce qui n'est pas choisi finit placé d'office par l'ordonnanceur.
"""

from __future__ import annotations

import logging
from datetime import date, datetime

from api.base import executer, lister, un_seul

LOG = logging.getLogger(__name__)


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


def possibilites(id_utilisateur: int, jour: date | None = None) -> list[dict]:
    """Tous les créneaux praticables des semaines ouvertes (SPT-16).

    La semaine en cours et la suivante, plus une troisième à partir du jeudi.
    `jour` sert à se placer à une autre date, pour les tests.
    """
    return lister(
        """
        SELECT lundi, jour, id_lieu, code, libelle, rang,
               lower(creneau) AS debut, upper(creneau) AS fin
          FROM creneaux_sport_horizon(%(u)s, %(j)s)
         ORDER BY jour, rang
        """,
        {"u": id_utilisateur, "j": jour},
    )


def restantes(id_utilisateur: int, jour: date | None = None) -> int:
    """Séances à caser sur tout l'horizon ouvert, pas sur la seule semaine."""
    ligne = un_seul("SELECT seances_sport_a_caser(%(u)s, %(j)s) AS n",
                    {"u": id_utilisateur, "j": jour})
    return (ligne or {}).get("n", 0)


def retenir(id_utilisateur: int, jour: date, id_lieu: int) -> dict | None:
    """Fixe une séance sur un jour et un lieu, et l'épingle."""
    ligne = un_seul(
        "SELECT retenir_seance_sport(%(u)s, %(j)s, %(l)s) AS id_occurrence",
        {"u": id_utilisateur, "j": jour, "l": id_lieu},
    )
    if ligne is None:
        return None

    return un_seul(
        """
        SELECT o.id_occurrence, l.libelle AS lieu,
               lower(o.creneau) AS debut, upper(o.creneau) AS fin
          FROM occurrence o
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_occurrence = %(id)s
        """,
        {"id": ligne["id_occurrence"]},
    )


def _entete_semaine(lundi: date, reference: date) -> str:
    """« Cette semaine », « Semaine prochaine », ou la date du lundi."""
    ecart = (lundi - reference).days // 7
    if ecart <= 0:
        return "Cette semaine"
    if ecart == 1:
        return "Semaine prochaine"
    return f"Semaine du {lundi.day:02d}/{lundi.month:02d}"


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


def caler(id_utilisateur: int, debut: datetime, nom_lieu: str = "") -> dict | None:
    """Pose une séance à l'heure exacte demandée, et l'épingle.

    L'heure est celle de la séance. Le trajet et les marges s'ajoutent autour,
    et c'est le bloc complet qu'on rend, pour qu'on voie ce qui est réservé.
    """
    lieu = lieu_par_nom(nom_lieu) if nom_lieu else None
    if nom_lieu and lieu is None:
        raise ValueError(f"Lieu inconnu : « {nom_lieu} »")

    ligne = un_seul(
        "SELECT caler_seance_sport(%(u)s, %(d)s, %(l)s) AS id_occurrence",
        {"u": id_utilisateur, "d": debut, "l": lieu["id_lieu"] if lieu else None},
    )
    if ligne is None:
        return None

    return un_seul(
        """
        SELECT o.id_occurrence, l.libelle AS lieu,
               lower(o.creneau) AS debut, upper(o.creneau) AS fin
          FROM occurrence o
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_occurrence = %(id)s
        """,
        {"id": ligne["id_occurrence"]},
    )


def resumer(id_utilisateur: int, jour: date | None = None) -> str | None:
    """Le message d'organisation, ou None s'il n'y a rien à proposer.

    Un jour par ligne, avec les lieux possibles, groupés par semaine. Les jours
    sans aucune possibilité sont tus : les afficher ferait une liste de refus.
    """
    from datetime import date as _date
    from datetime import timedelta

    from api.conversation import _heure

    a_caser = restantes(id_utilisateur, jour)
    if a_caser <= 0:
        return None

    creneaux = possibilites(id_utilisateur, jour)
    if not creneaux:
        return ("Sport : aucun créneau ne tient sur les semaines ouvertes.\n"
                "Ni la piscine, ni la course, ni la salle n'entrent dans "
                "l'emploi du temps.")

    JOURS = ("lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche")
    aujourd_hui = jour or _date.today()
    semaine_courante = aujourd_hui - timedelta(days=aujourd_hui.weekday())

    par_semaine: dict[date, dict[date, list[dict]]] = {}
    for creneau in creneaux:
        par_semaine.setdefault(creneau["lundi"], {}) \
                   .setdefault(creneau["jour"], []).append(creneau)

    lignes = [f"Sport : {a_caser} séance(s) à caser.", ""]
    for lundi_semaine in sorted(par_semaine):
        lignes.append(f"<b>{_entete_semaine(lundi_semaine, semaine_courante)}</b>")
        for jour_creneau in sorted(par_semaine[lundi_semaine]):
            titre = (f"{JOURS[jour_creneau.weekday()]} "
                     f"{jour_creneau.day:02d}/{jour_creneau.month:02d}")
            detail = " · ".join(
                f"{o['libelle']} {_heure(o['debut'])}"
                for o in par_semaine[lundi_semaine][jour_creneau])
            lignes.append(f"{titre} : {detail}")
        lignes.append("")

    lignes.append("Choisis, ou laisse faire : ce qui reste sera placé d'office.")
    return "\n".join(lignes)


def proposer(id_utilisateur: int | None = None) -> dict:
    """Dépose la proposition du lundi. C'est ce que l'ordonnanceur appelle.

    Une notification de type « sport », que le bot reconnaît pour y accrocher
    les boutons de choix.
    """
    destinataires = lister(
        "SELECT id_utilisateur FROM utilisateur "
        " WHERE actif AND (%(u)s::INT IS NULL OR id_utilisateur = %(u)s)"
        " ORDER BY id_utilisateur",
        {"u": id_utilisateur},
    )

    envoyees = 0
    for personne in destinataires:
        texte = resumer(personne["id_utilisateur"])
        if texte is None:
            continue

        executer(
            "INSERT INTO notification (id_utilisateur, type, contenu) "
            "VALUES (%(u)s, 'sport', %(t)s) RETURNING id_notification",
            {"u": personne["id_utilisateur"], "t": texte},
        )
        envoyees += 1

    if envoyees:
        LOG.info("Propositions de sport : %s message(s)", envoyees)
    return {"proposees": envoyees}
