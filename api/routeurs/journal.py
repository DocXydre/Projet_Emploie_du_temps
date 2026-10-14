"""Le journal des événements, par l'API."""

from datetime import datetime

from fastapi import APIRouter, Query

from api import journal
from api.securite import Authentifie

routeur = APIRouter(prefix="/journal", tags=["Journal"])


@routeur.get("", summary="Ce qui a changé, et ce qui l'a déclenché")
def lire_le_journal(
    qui: Authentifie,
    mot: str | None = Query(default=None, max_length=60,
                            description="Ne garder que les actions qui parlent de ce mot : "
                            "une tâche, un prénom, un lieu"),
    actions: int = Query(default=20, ge=1, le=100),
    avant: datetime | None = Query(default=None, description="La suite : les actions "
                                   "finies avant cet instant, le « quand » de la dernière reçue"),
) -> list[dict]:
    """JRN-9 : les dernières actions, avec ce que chacune a changé. C'est ce que
    lit l'écran Historique de l'appli [5.17].

    Une action est une commande du bot, un appel de l'API ou un passage de
    l'ordonnanceur. Ses événements partagent le même numéro d'opération : la
    cause et l'effet se lisent ensemble.

    Avec un mot, chaque action garde tous ses événements, et `correspond` dit
    lesquels parlent du mot : le reste montre ce qui s'est passé à côté. Ce qui
    relève du cours ordinaire des choses, un message parti, un courriel sans
    billet, n'est pas rendu.

    JRN-6 : tout le foyer lit la même chose. Les événements techniques, sources
    en panne et déploiements, ne sont rendus qu'à l'administrateur.
    """
    rendues = []
    for action in journal.lire(mot, admin=qui.est_admin, actions=actions, avant=avant):
        lignes = [e for e in action["evenements"]
                  if e.get("correspond") or not journal.routine(e)]
        if not lignes:
            continue
        rendues.append({
            "operation": action["operation"],
            "quand": action["quand"],
            "acteur": action["acteur"],
            "qui": action["qui"],
            "origine": action["origine"],
            "action": journal.origine_lisible(action["origine"]),
            "evenements": [
                {"objet": e["objet"], "id_objet": e["id_objet"], "phrase": e["phrase"],
                 "avant": e["avant"], "apres": e["apres"], "detail": e["detail"],
                 "technique": e["technique"], "quand": e["quand"],
                 "correspond": bool(mot) and bool(e.get("correspond"))}
                for e in lignes
            ],
        })
    return rendues[:actions]
