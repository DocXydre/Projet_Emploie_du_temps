"""Horaires de train, via l'API SNCF (Navitia).

Ce module ne connaît que les horaires : il reçoit deux gares et un intervalle,
et rend des trajets. Les fenêtres de départ et les absences se décident
ailleurs.

Navitia rend des heures locales sans décalage (« 20260828T181200 ») : on leur
rattache le fuseau configuré à la lecture, sinon elles finiraient prises pour
de l'UTC.

Comme pour les flux iCalendar, une réponse déjà obtenue peut être injectée, ce
dont les tests se servent pour ne pas dépendre du réseau.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import httpx

from api.config import configuration

LOG = logging.getLogger(__name__)

BASE = "https://api.sncf.com/v1/coverage/sncf/journeys"

# Codes UIC, tels que Navitia les nomme. Ce sont les deux seules gares qui nous
# concernent : inutile d'embarquer un annuaire.
GARES = {
    "NANCY": ("stop_area:SNCF:87141002", "Nancy-Ville"),
    "SAINT_DIE": ("stop_area:SNCF:87144014", "Saint-Dié-des-Vosges"),
}

FORMAT_NAVITIA = "%Y%m%dT%H%M%S"


class TrajetImpossible(Exception):
    """Aucun horaire n'a pu être obtenu, et on sait dire pourquoi."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Trajet:
    depart: datetime
    arrivee: datetime
    correspondances: int
    resume: str

    @property
    def duree(self) -> timedelta:
        return self.arrivee - self.depart


def _instant(texte: str) -> datetime:
    return datetime.strptime(texte, FORMAT_NAVITIA).replace(
        tzinfo=ZoneInfo(configuration().fuseau)
    )


def _resumer(sections: list[dict], correspondances: int) -> str:
    """Une ligne lisible : le mode, et où l'on change.

    Sans les lieux de correspondance, deux trajets de même durée sont
    indiscernables — alors que changer à Lunéville ou à Épinal ne se vaut pas.
    """
    trains = [s for s in sections if s.get("type") == "public_transport"]
    modes = []
    for section in trains:
        mode = (section.get("display_informations") or {}).get("commercial_mode")
        if mode and mode not in modes:
            modes.append(mode)

    libelle = " + ".join(modes) or "Train"

    if correspondances == 0:
        return f"{libelle} direct"

    etapes = [
        (section.get("to") or {}).get("name", "").split(" (")[0]
        for section in trains[:-1]
    ]
    etapes = [e for e in etapes if e]
    ou = f" à {', '.join(etapes)}" if etapes else ""
    accord = "correspondance" if correspondances == 1 else "correspondances"
    return f"{libelle}, {correspondances} {accord}{ou}"


def analyser(charge: dict) -> list[Trajet]:
    """Lit une réponse Navitia. Ne fait aucun filtrage."""
    if "error" in charge:
        erreur = charge["error"] or {}
        raise TrajetImpossible(
            erreur.get("id", "erreur_sncf"),
            erreur.get("message", "La SNCF n'a pas répondu de trajet"),
        )

    trajets = []
    for journey in charge.get("journeys") or []:
        # Navitia renvoie aussi des itinéraires à pied quand les gares sont
        # proches. Ici elles ne le sont pas, mais un trajet sans train reste
        # un trajet qu'on ne veut pas proposer.
        sections = journey.get("sections") or []
        if not any(s.get("type") == "public_transport" for s in sections):
            continue

        correspondances = int(journey.get("nb_transfers") or 0)
        trajets.append(Trajet(
            depart=_instant(journey["departure_date_time"]),
            arrivee=_instant(journey["arrival_date_time"]),
            correspondances=correspondances,
            resume=_resumer(sections, correspondances),
        ))

    return sorted(trajets, key=lambda t: t.depart)


def parametres(gare_depart: str, gare_arrivee: str, instant: datetime,
               represente: str = "departure") -> dict:
    """Paramètres de l'appel, isolés pour être vérifiables sans réseau.

    `represente` décide du sens de la recherche, et ce n'est pas un détail.
    « departure » rend les premiers trains après l'instant donné ; « arrival »
    rend les derniers arrivés avant. Pour un retour, c'est la seconde qu'il
    faut : on ne cherche pas le premier train qui ramène, on cherche le dernier
    qui ramène à temps.
    """
    return {
        "from": gare_depart,
        "to": gare_arrivee,
        "datetime": instant.astimezone(ZoneInfo(configuration().fuseau))
                           .strftime(FORMAT_NAVITIA),
        "datetime_represents": represente,
        "count": 10,
        "data_freshness": "realtime",
    }


def interroger(gare_depart: str, gare_arrivee: str, instant: datetime,
               represente: str = "departure") -> dict:
    """Appelle l'API. Le jeton est le nom d'utilisateur, sans mot de passe."""
    jeton = configuration().sncf_token
    if not jeton:
        raise TrajetImpossible(
            "jeton_absent",
            "Pas de jeton SNCF. En demander un sur numerique.sncf.com, "
            "puis renseigner SNCF_TOKEN dans le .env.",
        )

    try:
        reponse = httpx.get(
            BASE,
            params=parametres(gare_depart, gare_arrivee, instant, represente),
            auth=(jeton, ""), timeout=20.0, follow_redirects=True)
    except httpx.HTTPError as erreur:
        raise TrajetImpossible("injoignable", f"API SNCF injoignable : {erreur}") from erreur

    if reponse.status_code == 401:
        raise TrajetImpossible("jeton_refuse", "Le jeton SNCF a été refusé")
    if reponse.status_code >= 400:
        # Navitia répond 404 avec un corps explicite quand il ne trouve pas de
        # solution : ce n'est pas une panne, c'est une réponse.
        try:
            return reponse.json()
        except ValueError:
            raise TrajetImpossible(
                "erreur_sncf", f"API SNCF : HTTP {reponse.status_code}") from None

    return reponse.json()


def chercher(
    depart: str,
    arrivee: str,
    pas_avant: datetime,
    arrive_avant: datetime | None = None,
    limite: int = 4,
    charge: dict | None = None,
    au_plus_tard: bool = False,
) -> list[Trajet]:
    """Trajets partant après `pas_avant`, et arrivés avant `arrive_avant`.

    `au_plus_tard` renverse la recherche, ce qui distingue un aller d'un
    retour : on part dès qu'on peut, on rentre le plus tard possible.
    """
    gare_depart = GARES.get(depart, (depart, depart))[0]
    gare_arrivee = GARES.get(arrivee, (arrivee, arrivee))[0]

    if charge is not None:
        brut = charge
    elif au_plus_tard:
        if arrive_avant is None:
            raise TrajetImpossible(
                "sans_borne",
                "Chercher le dernier train suppose de savoir avant quand rentrer",
            )
        # Recherche par heure d'arrivée, pour obtenir les derniers trains qui
        # arrivent avant la limite.
        brut = interroger(gare_depart, gare_arrivee, arrive_avant, "arrival")
    else:
        brut = interroger(gare_depart, gare_arrivee, pas_avant, "departure")

    retenus = [
        t for t in analyser(brut)
        if t.depart >= pas_avant and (arrive_avant is None or t.arrivee <= arrive_avant)
    ]

    if au_plus_tard:
        return sorted(retenus, key=lambda t: t.depart, reverse=True)[:limite]
    return retenus[:limite]
