"""Mes heures, et le « ! » de l'orbe                           (NOT-15, NOT-18)"""

from datetime import time

from fastapi import APIRouter
from pydantic import BaseModel

from api.base import executer, un_seul
from api.securite import Authentifie

routeur = APIRouter(prefix="/moi", tags=["Notifications"])


class Heures(BaseModel):
    """Toutes facultatives : seules celles qu'on donne changent."""

    bilan: time | None = None
    relance: time | None = None
    recap: time | None = None
    silence_debut: time | None = None
    silence_fin: time | None = None


def _heures(id_utilisateur: int) -> dict:
    ligne = un_seul(
        """SELECT heure_bilan AS bilan, heure_relance AS relance, heure_recap AS recap,
                  silence_debut, silence_fin
             FROM utilisateur WHERE id_utilisateur = %(u)s""",
        {"u": id_utilisateur})
    assert ligne is not None
    return {cle: valeur.strftime("%H:%M") for cle, valeur in ligne.items()}


@routeur.get("/heures", summary="Mes heures : bilan, relance, récap et silence")
def lire_heures(qui: Authentifie) -> dict:
    return _heures(qui.id_utilisateur)


@routeur.patch("/heures", summary="Régler mes heures : elles valent dès le lendemain")
def regler_heures(heures: Heures, qui: Authentifie) -> dict:
    executer(
        "SELECT regler_heures(%(u)s, %(b)s, %(r)s, %(c)s, %(sd)s, %(sf)s)",
        {"u": qui.id_utilisateur, "b": heures.bilan, "r": heures.relance,
         "c": heures.recap, "sd": heures.silence_debut, "sf": heures.silence_fin},
    )
    return _heures(qui.id_utilisateur)


@routeur.get("/orbe", summary="HAL a-t-il quelque chose à dire ?")
def orbe(qui: Authentifie) -> dict:
    """NOT-18 : le récap du soir, une réponse arrivée panneau fermé, ou un
    ajustement en attente mettent un « ! » sur l'orbe, jusqu'à ce qu'on l'ouvre."""
    ligne = un_seul(
        """
        SELECT (SELECT count(*) FROM notification n
                 WHERE n.id_utilisateur = u.id_utilisateur AND n.type = 'coach'
                   AND n.date_creation > COALESCE(u.orbe_vu_le, '-infinity')) AS messages,
               (SELECT count(*) FROM ajustement a
                  JOIN occurrence o ON o.id_occurrence = a.id_occurrence
                 WHERE o.id_utilisateur = u.id_utilisateur
                   AND a.statut = 'propose') AS ajustements
          FROM utilisateur u WHERE u.id_utilisateur = %(u)s
        """,
        {"u": qui.id_utilisateur})
    assert ligne is not None
    return {**ligne, "a_dire": bool(ligne["messages"] or ligne["ajustements"])}


@routeur.post("/orbe/vu", summary="Le panneau de HAL a été ouvert")
def orbe_vu(qui: Authentifie) -> dict:
    executer("UPDATE utilisateur SET orbe_vu_le = now() WHERE id_utilisateur = %(u)s",
             {"u": qui.id_utilisateur})
    # Un ajustement en attente garde son « ! » : il attend une réponse, pas un regard.
    return orbe(qui)
