"""Planning consolidé et relance du placement."""

from datetime import datetime, timedelta

from fastapi import APIRouter

from api.base import executer, lister
from api.config import configuration
from api.securite import Authentifie

routeur = APIRouter(prefix="/planning", tags=["Planning"])


@routeur.get("", summary="Planning consolidé sur une période")
def planning(
    qui: Authentifie,
    debut: datetime | None = None,
    fin: datetime | None = None,
    utilisateur: int | None = None,
) -> list[dict]:
    debut = debut or datetime.now().astimezone()
    fin = fin or debut + timedelta(days=configuration().horizon_jours)

    return lister(
        """
        SELECT nature, id, id_utilisateur, categorie, libelle,
               debut, fin, journee_entiere, statut, lieu, motif, nb_relances
          FROM v_planning
         WHERE debut < %(fin)s AND fin > %(debut)s
           -- Le cast est obligatoire : PostgreSQL refuse un paramètre nul
           -- dont il ne peut pas déduire le type.
           AND (%(utilisateur)s::INT IS NULL OR id_utilisateur = %(utilisateur)s::INT)
         ORDER BY debut, journee_entiere DESC, libelle
        """,
        {"debut": debut, "fin": fin, "utilisateur": utilisateur},
    )


@routeur.post("/placer", summary="Relancer le placement")
def placer(qui: Authentifie, horizon_jours: int | None = None) -> dict:
    resultat = executer(
        "SELECT placer_taches(%(horizon)s) AS placees",
        {"horizon": horizon_jours or configuration().horizon_jours},
    )
    assert resultat is not None

    non_placees = lister(
        """
        SELECT tache_libelle, motif FROM v_occurrence
         WHERE statut = 'a_placer' AND motif IS NOT NULL
         ORDER BY priorite
        """
    )
    return {"placees": resultat["placees"], "non_placees": non_placees}
