"""Rendre lisible ce que la base rend.

Le modèle lit du texte : une heure en UTC lui ferait proposer une séance deux
heures trop tôt. Tout instant est donc rendu à l'heure de Paris, sans
décalage à interpréter.
"""

from datetime import date, datetime, time
from decimal import Decimal
from zoneinfo import ZoneInfo

from api.config import configuration

JOURS = ("lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche")


def fuseau() -> ZoneInfo:
    return ZoneInfo(configuration().fuseau)


def maintenant() -> datetime:
    return datetime.now(fuseau())


def aujourd_hui() -> date:
    return maintenant().date()


def lundi_de(jour: date) -> date:
    from datetime import timedelta
    return jour - timedelta(days=jour.weekday())


def clair(valeur):
    """Une valeur de la base, telle qu'on peut l'écrire en JSON et la lire."""
    if isinstance(valeur, datetime):
        if valeur.tzinfo is not None:
            valeur = valeur.astimezone(fuseau())
        return valeur.strftime("%Y-%m-%d %H:%M")
    if isinstance(valeur, date):
        return valeur.isoformat()
    if isinstance(valeur, time):
        return valeur.strftime("%H:%M")
    if isinstance(valeur, Decimal):
        return float(valeur) if valeur % 1 else int(valeur)
    if isinstance(valeur, dict):
        return {cle: clair(v) for cle, v in valeur.items()}
    if isinstance(valeur, (list, tuple)):
        return [clair(v) for v in valeur]
    if hasattr(valeur, "lower") and hasattr(valeur, "upper") and hasattr(valeur, "isempty"):
        # Un intervalle PostgreSQL : ses deux bornes.
        return {"du": clair(valeur.lower), "au": clair(valeur.upper)}
    return valeur


def sans_vides(ligne: dict) -> dict:
    """Retire les colonnes vides : le modèle n'a pas à payer pour des null."""
    return {cle: v for cle, v in ligne.items() if v is not None and v != [] and v != ""}


def jour_en_clair(jour: date) -> str:
    return f"{JOURS[jour.weekday()]} {jour.day:02d}/{jour.month:02d}"
