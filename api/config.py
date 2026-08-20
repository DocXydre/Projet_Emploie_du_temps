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

    # Horizon de planification : jusqu'où le moteur place les tâches. Un mois,
    # pour qu'on puisse s'organiser, mais pas plus : au-delà, une lessive
    # planifiée ne veut rien dire tant qu'on ignore la charge de la semaine.
    horizon_jours: int = 35

    # Passé ce délai, un créneau déjà placé ne bouge plus. Un planning qui
    # change tous les matins ne sert à rien : on ne s'organise pas autour de
    # quelque chose qui se dérobe.
    stabilite_jours: int = 7

    # Horizon d'affichage du calendrier : jusqu'où le flux iCalendar expose ce
    # qu'on connaît. Long, car un cours de novembre est utile à voir même si
    # aucune tâche ne sera placée ce jour-là.
    horizon_calendrier_jours: int = 180

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
