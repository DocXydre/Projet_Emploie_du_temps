"""Amorçage au démarrage : renseigner les URL des flux depuis l'environnement.

Les URL ne sont pas versionnées — celle du planning de travail contient un
jeton d'accès personnel. Elles sont donc fournies par variable d'environnement,
et écrites en base au premier démarrage seulement : une URL déjà renseignée
depuis le bot n'est jamais écrasée.
"""

import logging

from api.base import executer
from api.config import configuration

LOG = logging.getLogger(__name__)


def amorcer_sources() -> dict[str, bool]:
    conf = configuration()
    urls = {"IDMC_ICS": conf.idmc_url_ics, "MCDO": conf.mcdo_url_ics}
    resultat = {}

    for code, url in urls.items():
        if not url:
            continue

        modifiee = executer(
            """
            UPDATE source SET url = %(url)s
             WHERE code = %(code)s AND url IS NULL
            RETURNING code
            """,
            {"code": code, "url": url},
        )
        resultat[code] = modifiee is not None
        if modifiee is not None:
            LOG.info("Source %s : URL renseignée depuis l'environnement", code)

    return resultat
