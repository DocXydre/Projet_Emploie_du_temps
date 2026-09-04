"""Organiser les séances de la semaine plutôt que de les imposer.

Le placement sait poser trois séances tout seul. Il ne sait pas qu'on préfère
courir le mardi et nager le jeudi — et c'est une décision qui se prend le lundi
matin, une fois l'emploi du temps connu, pas au fil de l'eau.

Ce module rassemble les possibilités et les présente. Le choix reste à faire,
et ce qui n'est pas choisi finit placé d'office par l'ordonnanceur.
"""

from __future__ import annotations

import logging
from datetime import date

from api.base import executer, lister, un_seul

LOG = logging.getLogger(__name__)


def possibilites(id_utilisateur: int, lundi: date | None = None) -> list[dict]:
    """Tous les créneaux praticables de la semaine, par jour et par lieu."""
    return lister(
        """
        SELECT jour, id_lieu, code, libelle, rang,
               lower(creneau) AS debut, upper(creneau) AS fin
          FROM creneaux_sport_semaine(%(u)s, %(l)s)
         ORDER BY jour, rang
        """,
        {"u": id_utilisateur, "l": lundi},
    )


def restantes(id_utilisateur: int, lundi: date | None = None) -> int:
    ligne = un_seul("SELECT seances_sport_restantes(%(u)s, %(l)s) AS n",
                    {"u": id_utilisateur, "l": lundi})
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


def resumer(id_utilisateur: int, lundi: date | None = None) -> str | None:
    """Le message du lundi, ou None s'il n'y a rien à proposer.

    Un jour par ligne, avec les lieux possibles. Les jours sans aucune
    possibilité sont tus : les afficher ferait une liste de refus.
    """
    from api.conversation import _heure

    a_caser = restantes(id_utilisateur, lundi)
    if a_caser <= 0:
        return None

    creneaux = possibilites(id_utilisateur, lundi)
    if not creneaux:
        return ("Semaine de sport : aucun créneau ne tient cette semaine.\n"
                "Ni la piscine, ni la course, ni la salle n'entrent dans "
                "l'emploi du temps.")

    JOURS = ("lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche")
    par_jour: dict[date, list[dict]] = {}
    for creneau in creneaux:
        par_jour.setdefault(creneau["jour"], []).append(creneau)

    lignes = [f"Sport : {a_caser} séance(s) à caser cette semaine.", ""]
    for jour, options in par_jour.items():
        titre = f"{JOURS[jour.weekday()]} {jour.day:02d}/{jour.month:02d}"
        detail = " · ".join(
            f"{o['libelle']} {_heure(o['debut'])}" for o in options)
        lignes.append(f"{titre} — {detail}")

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
