"""Le journal des événements, par l'API."""

from fastapi import APIRouter, Query

from api import journal
from api.securite import Authentifie

routeur = APIRouter(prefix="/journal", tags=["Journal"])


@routeur.get("", summary="Ce qui a changé, et ce qui l'a déclenché")
def lire_le_journal(
    qui: Authentifie,
    mot: str | None = Query(default=None, description="Ne garder que les actions "
                            "qui parlent de ce mot : une tâche, un prénom, un lieu"),
    actions: int = Query(default=20, ge=1, le=100),
) -> list[dict]:
    """JRN-9 : les dernières actions, avec ce que chacune a changé.

    Une action est une commande du bot, un appel de l'API ou un passage de
    l'ordonnanceur. Ses événements partagent le même numéro d'opération : la
    cause et l'effet se lisent ensemble.

    JRN-6 : tout le foyer lit la même chose. Les événements techniques, sources
    en panne et déploiements, ne sont rendus qu'à l'administrateur.
    """
    rendues = []
    for action in journal.lire(mot, admin=qui.est_admin, actions=actions):
        lignes = [e for e in action["evenements"] if not mot or e.get("correspond")]
        rendues.append({
            "operation": action["operation"],
            "quand": action["quand"],
            "acteur": action["acteur"],
            "origine": action["origine"],
            "evenements": [
                {"objet": e["objet"], "id_objet": e["id_objet"], "phrase": e["phrase"],
                 "avant": e["avant"], "apres": e["apres"], "detail": e["detail"],
                 "technique": e["technique"]}
                for e in lignes
            ],
        })
    return rendues[:actions]
