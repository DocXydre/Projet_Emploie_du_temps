"""File d'attente des notifications.

Une notification est d'abord enregistrée, puis envoyée. Le bot vient vider la
file et signale ce qu'il a réussi à transmettre : un échec d'envoi laisse la
ligne en attente plutôt que de la perdre (R28).
"""

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel

from api.base import executer, lister
from api.securite import Administrateur, Authentifie

routeur = APIRouter(prefix="/notifications", tags=["Notifications"])


@routeur.get("", summary="Notifications en attente d'envoi")
def en_attente(qui: Authentifie, toutes: bool = False, limite: int = 50) -> list[dict]:
    return lister(
        """
        SELECT n.id_notification, n.id_utilisateur, u.pseudo, u.id_telegram,
               n.id_occurrence, n.type, n.contenu, n.statut,
               n.date_creation, n.date_envoi,
               -- Les actions possibles voyagent avec la notification : le bot
               -- n'a pas à connaître la machine à états pour afficher ses boutons.
               o.actions_possibles, o.tache_libelle
          FROM notification n
          JOIN utilisateur u ON u.id_utilisateur = n.id_utilisateur
          LEFT JOIN v_occurrence o ON o.id_occurrence = n.id_occurrence
         WHERE (%(toutes)s::BOOLEAN OR n.statut = 'a_envoyer')
         ORDER BY n.date_creation
         LIMIT %(limite)s
        """,
        {"toutes": toutes, "limite": max(1, min(limite, 200))},
    )


class ResultatEnvoi(BaseModel):
    reussi: bool = True
    motif: str | None = None


@routeur.post("/{id_notification}/envoyee", summary="Marquer une notification comme transmise")
def marquer_envoyee(id_notification: int, qui: Authentifie,
                    resultat: ResultatEnvoi | None = None) -> dict:
    reussi = resultat.reussi if resultat else True

    modifiee = executer(
        """
        UPDATE notification
           SET statut     = CASE WHEN %(reussi)s THEN 'envoyee' ELSE 'echec' END,
               date_envoi = CASE WHEN %(reussi)s THEN now() ELSE date_envoi END
         WHERE id_notification = %(id)s
        RETURNING id_notification, statut, date_envoi
        """,
        {"id": id_notification, "reussi": reussi},
    )
    if modifiee is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable",
                    "message": f"Notification {id_notification} inconnue"},
        )
    return modifiee


@routeur.post("/bilan", summary="Déclencher le bilan du matin")
def bilan(qui: Administrateur) -> dict:
    resultat = executer("SELECT bilan_du_matin() AS creees")
    assert resultat is not None
    return resultat


@routeur.post("/relance", summary="Déclencher la relance du soir")
def relance(qui: Administrateur) -> dict:
    resultat = executer("SELECT relance_du_soir() AS creees")
    assert resultat is not None
    return resultat


@routeur.post("/report", summary="Reporter d'office les tâches du jour non faites")
def report(qui: Administrateur) -> dict:
    resultat = executer("SELECT reporter_taches_du_jour() AS reportees")
    assert resultat is not None
    return resultat
