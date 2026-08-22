"""Amorçage au démarrage : renseigner les URL des flux depuis l'environnement.

Les URL ne sont pas versionnées — celle du planning de travail contient un
jeton d'accès personnel. Elles sont donc fournies par variable d'environnement,
et écrites en base au premier démarrage seulement : une URL déjà renseignée
depuis le bot n'est jamais écrasée.
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
    les tâches resteraient sans assigné et le moteur refuserait de les placer.
    La logique elle-même vit dans `006_assignations.sql` — on ne fait ici que
    l'appeler, pour qu'il n'y ait pas deux définitions à maintenir.

    L'ordre des deux appels n'est pas indifférent : `appliquer_assignations`
    attribue à l'administrateur toute source encore orpheline, ce qui lui
    donnerait le calendrier personnel de Lorette. Les calendriers se
    rattachent donc d'abord à leur propriétaire (R85).
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
