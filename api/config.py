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

    # Profondeur du passé exposée par le flux iCalendar. Les occupations
    # collectées ne sont jamais supprimées une fois passées : sans cette
    # fenêtre, le téléphone les oubliait quand même, l'export commençant la
    # veille. Savoir ce qu'on faisait il y a six mois demande de l'exporter.
    historique_calendrier_jours: int = 180

    # Hôte par lequel le téléphone joint l'API, sous la forme « nom:port ».
    # Une adresse IP change de réseau en réseau et casse l'abonnement du
    # calendrier ; le nom Bonjour du Mac (« mon-mac.local »), lui, ne change
    # pas. Laissé vide, l'API déduit l'hôte de la requête reçue — ce qui suffit
    # depuis un navigateur mais pas pour le bot, qui n'en a aucune.
    hote_public: str = ""

    # URL des flux. Jamais versionnées : celle du planning de travail contient
    # un jeton d'accès personnel. Elles peuvent aussi être données depuis le bot.
    idmc_url_ics: str = ""
    mcdo_url_ics: str = ""

    # Jeton du bot. S'il est absent, l'API tourne et les notifications
    # s'accumulent en file.
    telegram_token: str = ""

    # --- Trajets en train ---------------------------------------------------
    # Jeton de l'API SNCF (Navitia). S'il est absent, les fenêtres de départ
    # se calculent toujours ; seule la proposition d'horaires est indisponible.
    sncf_token: str = ""
    gare_domicile: str = "NANCY"
    gare_famille: str = "SAINT_DIE"

    # Le temps d'aller à la gare après un cours ou un service. C'est ce qui
    # sépare un train qu'on peut prendre d'un train qu'on regarde partir.
    marge_trajet_minutes: int = 30

    # En deçà, le trajet coûte plus que le séjour ne rapporte : deux heures
    # trente de train pour une soirée n'a pas de sens.
    fenetre_absence_heures: int = 48

    # Jusqu'où chercher des fenêtres. Au-delà, l'emploi du temps n'est pas assez
    # sûr pour qu'un billet le soit.
    horizon_trajets_jours: int = 45

    # Le lieu tel qu'on le nomme, qui n'est pas la gare. On va à Lusse, on
    # descend à Saint-Dié.
    lieu_famille: str = "Lusse"

    # Quinze jours avant : un billet coûte encore peu et l'on peut s'organiser.
    proposition_delai_jours: int = 14

    # Trois jours avant : la relance, parce qu'entre les deux on a oublié. Une
    # seule, sans quoi le service devient du harcèlement et l'on coupe tout.
    proposition_relance_jours: int = 3

    # --- Boîte aux lettres --------------------------------------------------
    # Boîte où arrivent les confirmations SNCF. Sans configuration, la relève ne
    # démarre pas et le reste fonctionne normalement.
    imap_hote: str = ""
    imap_port: int = 993
    imap_utilisateur: str = ""
    imap_mot_de_passe: str = ""

    # Dossier lu. Sur Gmail, un libellé est un dossier : un filtre qui pose
    # « SNCF » sur les confirmations suffit, sans rien réexpédier ni créer de
    # compte. La boîte est ouverte en lecture seule, donc rien n'est marqué lu.
    imap_dossier: str = "INBOX"

    # Filtre appliqué par le serveur sur l'expéditeur, pour ne pas rapatrier
    # une boîte de réception entière. Il ne remplace pas la liste blanche du
    # lecteur, qui reste seule juge de ce qu'on accepte.
    imap_filtre_expediteur: str = "sncf"

    # Profondeur de la relève. Les courriels déjà vus sont reconnus à leur
    # Message-ID, donc relire large ne crée pas de doublon — seulement du
    # trafic.
    imap_depuis_jours: int = 30

    # Le compte à qui appartiennent les billets de cette boîte, par son pseudo.
    # Vide : ils reviennent à l'administrateur, comme avant.
    imap_pseudo: str = ""

    # --- Deuxième boîte ------------------------------------------------------
    # On vit à deux, et les confirmations SNCF arrivent chacune dans sa boîte.
    # Renseigner IMAP2_* ajoute une boîte à relever ; la laisser vide n'ajoute
    # rien et ne change rien au reste.
    imap2_hote: str = ""
    imap2_port: int = 993
    imap2_utilisateur: str = ""
    imap2_mot_de_passe: str = ""
    imap2_dossier: str = "INBOX"
    imap2_filtre_expediteur: str = "sncf"
    imap2_pseudo: str = ""

    # L'ordonnanceur est désactivé pendant les tests : on déclenche les tâches
    # à la main pour ne pas dépendre de l'heure qu'il est.
    ordonnanceur_actif: bool = True

    version: str = "0.1.0"

    @property
    def boites(self) -> list[dict]:
        """Les boîtes à relever, avec le compte auquel rattacher leurs billets.

        Une liste plutôt qu'une boîte unique : à deux, chacun reçoit ses
        confirmations chez lui, et un billet rattaché à la mauvaise personne
        gèlerait le planning de quelqu'un qui n'est pas parti (BIL-10).
        """
        boites = []
        if self.imap_hote and self.imap_utilisateur and self.imap_mot_de_passe:
            boites.append({
                "hote": self.imap_hote, "port": self.imap_port,
                "utilisateur": self.imap_utilisateur,
                "mot_de_passe": self.imap_mot_de_passe,
                "dossier": self.imap_dossier,
                "filtre": self.imap_filtre_expediteur,
                "pseudo": self.imap_pseudo or None,
            })
        if self.imap2_hote and self.imap2_utilisateur and self.imap2_mot_de_passe:
            boites.append({
                "hote": self.imap2_hote, "port": self.imap2_port,
                "utilisateur": self.imap2_utilisateur,
                "mot_de_passe": self.imap2_mot_de_passe,
                "dossier": self.imap2_dossier,
                "filtre": self.imap2_filtre_expediteur,
                "pseudo": self.imap2_pseudo or None,
            })
        return boites

    @property
    def url_base(self) -> str:
        return (
            f"postgresql://{self.postgres_user}:{self.postgres_password}"
            f"@{self.db_hote}:{self.db_port}/{self.postgres_db}"
        )


@lru_cache
def configuration() -> Configuration:
    return Configuration()
