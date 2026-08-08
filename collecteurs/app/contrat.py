"""Contrat commun a tous les collecteurs (cf. cahier des charges, 7.1 A.1).

Tout collecteur, sans exception, expose quatre operations :

    recuperer()  -> donnees brutes de la source
    normaliser() -> liste d'occupations portant une cle externe
    publier()    -> envoi au coeur metier, qui reconcilie par cle externe
    sante()      -> etat du collecteur

La cle externe (UID d'un evenement ICS, identifiant de shift) est ce qui permet
au coeur de mettre a jour au lieu de dupliquer.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from datetime import datetime
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, Field


class EtatSante(StrEnum):
    OK = "OK"
    DEGRADE = "DEGRADE"
    MORT = "MORT"


class TypeOccupation(StrEnum):
    COURS = "COURS"
    SHIFT = "SHIFT"
    TRAJET = "TRAJET"
    SOMMEIL = "SOMMEIL"
    PERSO = "PERSO"


class Occupation(BaseModel):
    """Occupation normalisee, telle qu'attendue par le coeur metier."""

    cle_externe: str = Field(description="Identifiant stable dans la source, sert a la reconciliation")
    type: TypeOccupation
    debut: datetime = Field(description="Horodatage avec fuseau explicite, ISO 8601")
    fin: datetime
    libelle: str
    lieu: str | None = None
    annulee: bool = False


class SanteCollecteur(BaseModel):
    code_source: str
    etat: EtatSante
    derniere_collecte_ok: datetime | None = None
    derniere_collecte_tentee: datetime | None = None
    message: str | None = None


class ResultatCollecte(BaseModel):
    code_source: str
    occupations: list[Occupation] = []
    duree_ms: int = 0
    message: str | None = None


class Collecteur(ABC):
    """Classe de base des collecteurs. Une sous-classe par source."""

    #: Doit correspondre au code de la table `source_contrainte` cote coeur.
    code_source: str

    @abstractmethod
    async def recuperer(self) -> Any:
        """Obtient les donnees brutes de la source externe."""

    @abstractmethod
    async def normaliser(self, brut: Any) -> list[Occupation]:
        """Transforme les donnees brutes en occupations portant une cle externe."""

    @abstractmethod
    async def publier(self, occupations: list[Occupation]) -> None:
        """Envoie les occupations au coeur metier, qui reconcilie par cle externe."""

    @abstractmethod
    async def sante(self) -> SanteCollecteur:
        """Etat courant du collecteur, y compris la fraicheur de la derniere collecte."""

    async def executer(self) -> ResultatCollecte:
        """Cycle complet. Le pilotage du backoff reste a la charge de l'ordonnanceur."""
        brut = await self.recuperer()
        occupations = await self.normaliser(brut)
        await self.publier(occupations)
        return ResultatCollecte(code_source=self.code_source, occupations=occupations)
