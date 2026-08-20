"""Configuration lue depuis l'environnement.

Aucun secret n'est écrit en dur ni versionné.
"""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Configuration(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    postgres_db: str = "planif"
    postgres_user: str = "planif"
    postgres_password: str = "planif"
    db_hote: str = "localhost"
    db_port: int = 5432

    # Fuseau d'affichage. Le stockage reste en UTC.
    fuseau: str = "Europe/Paris"

    # Horizon de planification, en jours.
    horizon_jours: int = 21

    # URL des flux. Jamais versionnées : celle du planning de travail contient
    # un jeton d'accès personnel. Elles peuvent aussi être données depuis le bot.
    idmc_url_ics: str = ""
    mcdo_url_ics: str = ""

    # Jeton du bot. Sans lui, l'API tourne mais les notifications restent en file.
    telegram_token: str = ""

    # L'ordonnanceur est désactivé pendant les tests : on déclenche les tâches
    # à la main pour ne pas dépendre de l'heure qu'il est.
    ordonnanceur_actif: bool = True

    version: str = "0.1.0"

    @property
    def url_base(self) -> str:
        return (
            f"postgresql://{self.postgres_user}:{self.postgres_password}"
            f"@{self.db_hote}:{self.db_port}/{self.postgres_db}"
        )


@lru_cache
def configuration() -> Configuration:
    return Configuration()
