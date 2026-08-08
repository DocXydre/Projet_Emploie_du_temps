"""Configuration du service de collecte, lue depuis l'environnement.

Aucun secret n'est ecrit en dur ni versionne : les identifiants de portail et
les acces IMAP sont fournis par variable d'environnement ou, a terme, chiffres
en base cote coeur metier (cf. cahier des charges, 9).
"""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Configuration(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="PLANIF_", env_file=".env", extra="ignore")

    version: str = "0.1.0"
    service: str = "planif-collecteurs"

    # Le coeur metier n'est joignable que depuis le reseau Docker interne.
    url_coeur: str = "http://coeur:8080"
    jeton_interne: str = ""
    delai_appel_secondes: float = 10.0

    # Resilience commune a tous les collecteurs (cf. 7.1 A.1).
    tentatives_max: int = 5
    backoff_initial_secondes: float = 2.0


@lru_cache
def configuration() -> Configuration:
    return Configuration()
