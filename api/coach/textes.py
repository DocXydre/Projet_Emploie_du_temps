"""Deux aides du démarrage : lire une date écrite à la main, et dire le motif
d'un refus.                                                      (DEM-1 à DEM-4)"""

import re
from datetime import date, timedelta

import psycopg

from api.coach.clair import aujourd_hui
from api.erreurs import refus_coach


def message_d_erreur(erreur: Exception) -> str:
    refus = refus_coach(erreur) if isinstance(erreur, psycopg.Error) else None
    if refus is not None:
        return refus["message"]
    detail = getattr(erreur, "detail", None)
    if isinstance(detail, dict) and detail.get("message"):
        return detail["message"]
    diag = getattr(erreur, "diag", None)
    if diag is not None and diag.message_primary:
        return diag.message_primary
    return "Impossible pour l'instant."


def lire_jour(mot: str) -> date | None:
    """« 08/10 », « 08/10/2026 », « 2026-10-08 », « demain », « aujourd'hui »."""
    mot = mot.strip().lower()
    jour = aujourd_hui()
    if mot in ("aujourd'hui", "aujourdhui", "auj"):
        return jour
    if mot == "demain":
        return jour + timedelta(days=1)
    try:
        return date.fromisoformat(mot)
    except ValueError:
        pass
    trouve = re.fullmatch(r"(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?", mot)
    if not trouve:
        return None
    annee = int(trouve.group(3)) if trouve.group(3) else jour.year
    if annee < 100:
        annee += 2000
    try:
        lu = date(annee, int(trouve.group(2)), int(trouve.group(1)))
    except ValueError:
        return None
    # Sans année, une date déjà passée désigne l'an prochain.
    if not trouve.group(3) and lu < jour - timedelta(days=60):
        lu = lu.replace(year=annee + 1)
    return lu
