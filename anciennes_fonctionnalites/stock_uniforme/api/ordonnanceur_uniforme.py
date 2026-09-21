"""Tâche de nuit du stock d'uniforme, retirée de api/ordonnanceur.py.

Elle tournait à 00h02, juste avant le report d'office :

    # Avant le report : un t-shirt sali cette nuit peut avancer l'échéance de
    # la lessive, et donc changer ce qu'il y a à replacer.
    ordonnanceur.add_job(consommer_l_uniforme, a(0, 2),
                         id="uniforme", name="Consommation de l'uniforme",
                         coalesce=True)
"""

import logging

from api.base import executer
from api.ordonnanceur import placer

LOG = logging.getLogger(__name__)


def consommer_l_uniforme() -> int:
    """Compte les journées de travail passées, et salit ce qui doit l'être.

    Traite tous les jours non encore comptés, et pas seulement la veille : la
    machine peut avoir été éteinte plusieurs jours.
    """
    resultat = executer("SELECT rattraper_uniforme() AS sales")
    sales = (resultat or {}).get("sales", 0)
    if sales:
        LOG.info("Uniforme : %s article(s) au sale", sales)
        # Le stock a changé : la date limite de lessive aussi.
        placer()
    return sales
