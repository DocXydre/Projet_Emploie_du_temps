"""Le sport, ce qui reste du module d'avant HAL.

HAL propose les séances sur quatre semaines (SPT-33) ; l'appli les montre et
les valide. Ce module ne garde que ce qui ne dépend pas de lui : les horaires
publiés des lieux (SPT-15), et les séances à deux (SPT-31, SPT-32).

L'organisation d'avant, réservations « à déterminer », habitudes,
propositions du moteur, minimum et alerte du lundi, est rangée dans
`anciennes_fonctionnalites/reservations_sport/`.
"""

from __future__ import annotations

import logging
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from api.base import lister, un_seul
from api.config import configuration

LOG = logging.getLogger(__name__)


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
# Dates
# ---------------------------------------------------------------------------

def _fuseau() -> ZoneInfo:
    return ZoneInfo(configuration().fuseau)


def aujourd_hui() -> date:
    return datetime.now(_fuseau()).date()


def lundi_de(jour: date) -> date:
    return jour - timedelta(days=jour.weekday())


# ---------------------------------------------------------------------------
# Une séance posée à la main                                   (SPT-19, SPT-21)
# ---------------------------------------------------------------------------

def choisir(id_utilisateur: int, id_lieu: int, debut: datetime,
            occurrence: int | None = None) -> int:
    """Pose une séance à l'heure dite, ou déplace celle donnée. Règles souples."""
    ligne = un_seul("SELECT choisir_seance_sport(%(u)s, %(l)s, %(d)s, %(o)s) AS id",
                    {"u": id_utilisateur, "l": id_lieu, "d": debut, "o": occurrence})
    return ligne["id"]


# ---------------------------------------------------------------------------
# Les séances à deux                                         (SPT-30 à SPT-32)
# ---------------------------------------------------------------------------

def possible_a_deux(id_utilisateur: int, id_lieu: int, debut: datetime) -> bool:
    """SPT-30 : quelqu'un d'autre tient-il ce créneau, au même endroit ?"""
    ligne = un_seul(
        "SELECT seance_possible_a_deux(%(u)s, %(l)s, %(d)s) AS oui",
        {"u": id_utilisateur, "l": id_lieu, "d": debut},
    )
    return bool(ligne and ligne["oui"])


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
