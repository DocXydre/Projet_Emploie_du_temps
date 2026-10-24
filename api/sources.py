"""Les sources suivies : leur adresse, et l'arrêt d'un flux        (COL-21)

La collecte elle-même vit dans api/collecteurs/.
"""

from __future__ import annotations

from api.base import executer


def url_collectable(url: str) -> str:
    """Ramène une URL d'abonnement à quelque chose qu'un client HTTP sait lire.

    Apple, Google et Outlook donnent des liens en `webcal://`. Ce préfixe sert
    seulement à ouvrir l'application Calendrier : derrière, c'est du HTTPS. On
    le remplace donc avant de collecter.
    """
    url = url.strip()
    if url.lower().startswith("webcal://"):
        return "https://" + url[len("webcal://"):]
    return url


def arreter_source(code: str) -> dict | None:
    """Cesse de suivre un flux, et replace ce que ses créneaux bloquaient.

    COL-21 : l'avenir de la source disparaît du planning, son passé reste.
    """
    ligne = executer("SELECT arreter_source(%(c)s) AS bilan", {"c": code})
    bilan = (ligne or {}).get("bilan")
    if bilan is None:
        return None

    # Les créneaux libérés sont aussitôt disponibles pour le reste.
    from api.ordonnanceur import placer
    bilan["occurrences_replacees"] = placer()
    return bilan
