"""Amorçage au démarrage : URL des flux et assignations par défaut.

Les URL ne sont pas versionnées — celle du planning de travail contient un
jeton personnel. Elles viennent de l'environnement et ne sont écrites qu'au
premier démarrage : une URL déjà donnée par le bot n'est jamais écrasée.
"""

import logging

import psycopg

from api.base import executer
from api.config import configuration

LOG = logging.getLogger(__name__)


def amorcer_sources() -> dict[str, bool]:
    """Renseigne les URL manquantes. Ne fait jamais échouer le démarrage.

    Au tout premier lancement, l'API démarre avant que les migrations n'aient
    été appliquées : la table `source` n'existe pas encore. Ce n'est pas une
    erreur, c'est l'ordre normal des choses. L'amorçage se refera au prochain
    redémarrage, une fois le schéma en place.
    """
    conf = configuration()
    urls = {"IDMC_ICS": conf.idmc_url_ics, "MCDO": conf.mcdo_url_ics}
    resultat = {}

    for code, url in urls.items():
        if not url:
            continue

        try:
            modifiee = executer(
                """
                UPDATE source SET url = %(url)s
                 WHERE code = %(code)s AND url IS NULL
                RETURNING code
                """,
                {"code": code, "url": url},
            )
        except psycopg.Error as erreur:
            LOG.warning("Amorçage de %s reporté : %s", code, erreur.diag.message_primary or erreur)
            continue

        resultat[code] = modifiee is not None
        if modifiee is not None:
            LOG.info("Source %s : URL renseignée depuis l'environnement", code)

    return resultat


def amorcer_assignations() -> int:
    """Rejoue les assignations par défaut.

    Les comptes sont souvent créés après les migrations : sans ce rattrapage,
    les tâches resteraient sans assigné.

    L'ordre compte : `appliquer_assignations` donne à l'administrateur toute
    source orpheline, donc les calendriers personnels passent d'abord (COL-16).
    """
    touchees = 0
    try:
        perso = executer("SELECT assigner_calendriers_perso() AS touchees")
        touchees += (perso or {}).get("touchees", 0)

        resultat = executer("SELECT appliquer_assignations() AS touchees")
    except psycopg.Error as erreur:
        LOG.warning("Assignations reportées : %s", erreur.diag.message_primary or erreur)
        return 0

    touchees += (resultat or {}).get("touchees", 0)
    if touchees:
        LOG.info("Assignations par défaut : %s ligne(s) mise(s) à jour", touchees)
    return touchees
