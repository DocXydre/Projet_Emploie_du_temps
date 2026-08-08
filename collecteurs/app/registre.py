"""Registre des collecteurs disponibles.

Vide au lot 0 : les collecteurs arrivent au lot 2 (ICS IDMC), au lot 5 (portail
McDonald's), au lot 7 (SUAPS) et au lot 8 (boite mail dediee). Le registre
existe des maintenant pour que l'ajout d'une source ne demande aucune
modification de l'API du service.
"""

from app.contrat import Collecteur

_COLLECTEURS: dict[str, Collecteur] = {}


def enregistrer(collecteur: Collecteur) -> None:
    _COLLECTEURS[collecteur.code_source] = collecteur


def par_code(code_source: str) -> Collecteur | None:
    return _COLLECTEURS.get(code_source)


def tous() -> list[Collecteur]:
    return list(_COLLECTEURS.values())


def codes() -> list[str]:
    return sorted(_COLLECTEURS)
