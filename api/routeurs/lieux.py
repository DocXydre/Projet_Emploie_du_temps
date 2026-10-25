"""Lieux, position et météo, pour l'appli                       (section H.8.1)

L'appli lit ses lieux pour savoir quels cercles surveiller (POS-2), envoie une
position à chaque passage, et lit la météo de ses séances dehors et de ses
courses (MTO-9). Chaque route ne parle que du compte qui appelle (POS-5).

Un lieu s'ajoute ici au démarrage, avec son nom, son adresse et sa description
(DEM-7). Ensuite, la description, le mode et la nature se disent à HAL : seule
l'adresse se corrige à la main (ADR-6).
"""

from datetime import date, datetime, time, timedelta
from decimal import Decimal

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api import lieux, meteo, position
from api.coach.clair import aujourd_hui, fuseau
from api.securite import Authentifie

routeur = APIRouter(prefix="/appli", tags=["Appli : lieux et météo"])


def _lieu(x: dict) -> dict:
    return {**x, "latitude": float(x["latitude"]), "longitude": float(x["longitude"])}


@routeur.get("/lieux", summary="Mes lieux connus, et où le serveur me croit")
def mes_lieux(qui: Authentifie) -> dict:
    u = qui.id_utilisateur
    rendu = []
    for x in lieux.lieux_du_compte(u):
        x = _lieu(x)
        x["trajets_depuis"] = lieux.trajets_vers(u, x["id_lieu_connu"])
        rendu.append(x)
    return {"lieux": rendu, "position": _position(u)}


class NouveauLieu(BaseModel):
    nom: str = Field(min_length=1, max_length=60)
    adresse: str = Field(min_length=3, max_length=200)
    nature: str = Field(pattern="^(foyer|sport|etudes|travail|sejour|autre)$")
    description: str | None = Field(default=None, max_length=1000)


@routeur.post("/lieux", status_code=status.HTTP_201_CREATED, summary="Ajouter un lieu")
def ajouter(corps: NouveauLieu, qui: Authentifie) -> dict:
    """DEM-7 : une adresse du démarrage, cherchée avant d'être gardée. Un lieu du même
    nom est mis à jour : refaire l'étape ne crée pas de doublon."""
    try:
        lieu = lieux.noter_lieu(qui.id_utilisateur, nom=corps.nom, adresse=corps.adresse,
                                nature=corps.nature, description=corps.description)
    except lieux.AdresseIntrouvable as erreur:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                            detail={"code": "adresse_introuvable",
                                    "message": str(erreur)}) from None
    except ValueError as erreur:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
                            detail={"code": "requete_invalide", "message": str(erreur)}) from None
    return _lieu(lieu)


class Correction(BaseModel):
    adresse: str = Field(min_length=3, max_length=200)


@routeur.patch("/lieux/{id_lieu_connu}", summary="Corriger l'adresse d'un lieu")
def corriger(id_lieu_connu: int, corps: Correction, qui: Authentifie) -> dict:
    """ADR-6 : l'adresse est cherchée avant d'être gardée ; les trajets se refont."""
    try:
        lieu = lieux.noter_lieu(qui.id_utilisateur, id_lieu_connu=id_lieu_connu,
                                adresse=corps.adresse)
    except lieux.AdresseIntrouvable as erreur:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                            detail={"code": "adresse_introuvable",
                                    "message": str(erreur)}) from None
    except ValueError as erreur:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail={"code": "introuvable", "message": str(erreur)}) from None
    return _lieu(lieu)


class Position(BaseModel):
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    precision_m: float | None = Field(default=None, ge=0)
    instant: datetime | None = None
    autorisation: str = Field(default="inconnue",
                              pattern="^(toujours|utilisation|refusee|inconnue)$")
    precise: bool = False
    # Réveillé par la sortie d'un cercle, sans le temps d'un relevé.
    sortie_de: int | None = None


def _position(u: int) -> dict:
    ici = lieux.ou_je_suis(u)
    return {"sue": bool(ici.get("sue")), "lieu": ici.get("nom"),
            "id_lieu_connu": ici.get("id_lieu_connu"), "depuis": ici.get("depuis"),
            "autorisation": ici.get("autorisation") or "inconnue",
            "precise": bool(ici.get("precise")), "ecrit_le": ici.get("ecrit_le")}


@routeur.post("/position", summary="Une position de l'iPhone")
def recevoir(corps: Position, qui: Authentifie) -> dict:
    """POS-2 à POS-4 : la base rattache la position à un lieu, et garde le passage.
    Les questions de HAL viennent après, au passage suivant du travailleur."""
    return position.recevoir(qui.id_utilisateur, corps.latitude, corps.longitude,
                             corps.precision_m, corps.instant, corps.autorisation,
                             corps.precise, corps.sortie_de)


@routeur.get("/position", summary="Où le serveur me croit")
def ou_suis_je(qui: Authentifie) -> dict:
    return _position(qui.id_utilisateur)


def _nombres(ligne: dict) -> dict:
    """Les NUMERIC de la base en nombres : FastAPI écrirait « 12.9 » entre guillemets."""
    return {cle: float(v) if isinstance(v, Decimal) else v for cle, v in ligne.items()}


def _heure(h: dict) -> dict:
    return _nombres({
        "heure": h["heure"], "temperature": h["temperature"], "ressenti": h["ressenti"],
        "pluie_mm": h["pluie_mm"], "pluie_proba": h["pluie_proba"],
        "vent_kmh": h["vent_kmh"], "rafales_kmh": h["rafales_kmh"],
        "direction": meteo.direction(h["direction_deg"]),
        "direction_deg": h["direction_deg"], "code_temps": h["code_temps"]})


@routeur.get("/meteo/seances", summary="La météo de mes séances dehors")
def meteo_des_seances(qui: Authentifie, du: date | None = None,
                      au: date | None = None) -> list[dict]:
    """MTO-9 : à l'heure de chaque séance dehors, de aujourd'hui à sept jours."""
    du = du or aujourd_hui()
    au = min(au or du + timedelta(days=7), aujourd_hui() + timedelta(days=7))
    rendu = []
    for s in meteo.seances_dehors(qui.id_utilisateur, datetime.combine(du, time(0), fuseau()),
                                  datetime.combine(au + timedelta(days=1), time(0), fuseau())):
        heures = meteo.pendant(s)
        if not heures:
            continue
        rendu.append({"id_occurrence": s["id_occurrence"], "debut": s["debut"],
                      "point": s["point"], "a_l_heure": _heure(heures[0]),
                      "seuils": meteo.seuils_franchis(heures)})
    return rendu


@routeur.get("/meteo/activite/{id_activite}", summary="La météo d'une de mes courses")
def meteo_d_une_course(id_activite: int, qui: Authentifie) -> dict:
    """MTO-6, MTO-7 : relevée une fois, puis gardée. 404 sans tracé ni réponse."""
    m = meteo.de_l_activite(qui.id_utilisateur, id_activite)
    if m is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail={"code": "sans_meteo",
                                    "message": "Pas de météo pour cette activité"})
    return {**_nombres(m), "direction": meteo.direction(m["direction_deg"]),
            "en_clair": meteo.en_clair_de_l_activite(m)}
