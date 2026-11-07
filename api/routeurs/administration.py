"""Administration du serveur : ce que lit la veille d'Uzine.  (ADM-6)

Réservé à l'administrateur et au réseau privé (CNX-5).
"""

from fastapi import APIRouter

from api import administration
from api.securite import Administrateur

routeur = APIRouter(prefix="/admin", tags=["Administration"])


@routeur.get("/erreurs", summary="Les erreurs du jour, depuis un identifiant")
def erreurs(qui: Administrateur, depuis: int = 0) -> list[dict]:
    """ADM-6 : les erreurs d'id_erreur supérieur à `depuis`, de la plus ancienne à la plus récente,
    500 au plus."""
    return administration.erreurs_depuis(depuis, 500)
