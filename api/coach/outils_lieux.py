"""Les outils des lieux, de la soirée et de la météo                (partie H)

Les mêmes pour les deux HAL, sauf la soirée et la météo, qui ne vont qu'au HAL
sport (section H.8.2). Comme les autres outils, ils ne parlent que du compte
de l'appel (POS-5) : aucun ne prend de compte en paramètre.

    lieux    lire_lieux, noter_lieu, ecrire_description_lieu  (ADR-4, ADR-11, ADR-15)
    soiree   noter_soiree                                     (SOI-2, SOI-4)
    meteo    lire_meteo                                       (MTO-4, MTO-5)
"""

from datetime import date, datetime, time, timedelta

from api import lieux, meteo
from api.base import un_seul
from api.coach.clair import aujourd_hui, clair, fuseau, maintenant


def _refus():
    from api.coach.outils import RefusOutil
    return RefusOutil


def _objet(proprietes: dict, requis: list[str] | None = None) -> dict:
    return {"type": "object", "properties": proprietes, "required": requis or [],
            "additionalProperties": False}


def _jour(valeur, nom: str) -> date:
    try:
        return date.fromisoformat(str(valeur))
    except (TypeError, ValueError):
        raise _refus()("requete_invalide",
                       f"« {nom} » doit être une date au format AAAA-MM-JJ") from None


# ---------------------------------------------------------------------------
# Les lieux
# ---------------------------------------------------------------------------

def lire_lieux(u: int, a: dict) -> object:
    ici = lieux.ou_je_suis(u)
    rendu = []
    for x in lieux.lieux_du_compte(u):
        x = {cle: v for cle, v in x.items() if cle not in ("latitude", "longitude")}
        x["trajets_depuis"] = lieux.trajets_vers(u, x["id_lieu_connu"])
        rendu.append(x)
    return {"maintenant": (ici.get("nom") or "ailleurs") if ici.get("sue") and
            ici.get("id_presence") else "pas sue",
            "depuis": ici.get("depuis") if ici.get("sue") else None,
            "lieux": rendu}


def noter_lieu(auteur: str):
    def noter(u: int, a: dict) -> object:
        return _noter_lieu(u, a, auteur)
    return noter


def _noter_lieu(u: int, a: dict, auteur: str) -> object:
    try:
        lieu = lieux.noter_lieu(
            u, nom=a.get("nom"), adresse=a.get("adresse"), ici=bool(a.get("ici")),
            nature=a.get("nature"), rayon_m=a.get("rayon_m"),
            mode_trajet=a.get("mode_trajet"), id_lieu_sport=a.get("id_lieu_sport"),
            id_lieu_connu=a.get("id_lieu_connu"), description=a.get("description"),
            auteur=auteur)
    except lieux.AdresseIntrouvable as erreur:
        raise _refus()("adresse_introuvable", str(erreur)) from None
    except ValueError as erreur:
        raise _refus()("requete_invalide", str(erreur)) from None
    return {"fait": "lieu créé" if lieu["cree"] else "lieu mis à jour",
            "id_lieu_connu": lieu["id_lieu_connu"], "nom": lieu["nom"],
            "adresse_trouvee": lieu["adresse"], "nature": lieu["nature"],
            "mode_trajet": lieu["mode_trajet"], "rayon_m": lieu["rayon_m"],
            "description": lieu["description"],
            "trajets_depuis": lieu["trajets_depuis"],
            "note": "Répète l'adresse trouvée dans ta réponse : si ce n'est pas le bon "
                    "endroit, l'utilisateur la corrigera (ADR-4)."}


def ecrire_description_lieu(auteur: str):
    def ecrire(u: int, a: dict) -> object:
        version = lieux.ecrire_description(u, a.get("id_lieu_connu"), a.get("texte") or "",
                                           auteur)
        return {"fait": "description du lieu écrite" if a.get("texte")
                else "description effacée", "version": version}
    return ecrire


# ---------------------------------------------------------------------------
# La soirée
# ---------------------------------------------------------------------------

def _heure_du_coucher(nuit: date, valeur) -> datetime | None:
    """« 03:00 » se lit dans la nuit : le lendemain avant midi, le soir même après."""
    if not valeur:
        return None
    try:
        h = time.fromisoformat(str(valeur)[:5])
    except ValueError:
        try:
            return datetime.fromisoformat(str(valeur)).astimezone(fuseau())
        except ValueError:
            raise _refus()("requete_invalide",
                           "« couche_a » est une heure, HH:MM") from None
    jour = nuit + timedelta(days=1) if h.hour < 12 else nuit
    return datetime.combine(jour, h, fuseau())


def noter_soiree(u: int, a: dict) -> object:
    nuit = _jour(a["nuit"], "nuit") if a.get("nuit") else (
        aujourd_hui() - timedelta(days=1) if maintenant().hour < 14 else aujourd_hui())
    raconte = any(a.get(k) is not None for k in ("verres", "couche_a", "ressenti",
                                                    "commentaire"))
    statut = "ecartee" if a.get("pas_une_soiree") else "racontee" if raconte else "probable"
    deja = un_seul("SELECT origine FROM soiree WHERE id_utilisateur = %(u)s AND nuit = %(n)s",
                   {"u": u, "n": nuit})
    from api.base import executer
    ligne = executer(
        """SELECT noter_soiree(%(u)s, %(n)s, %(o)s, %(s)s, %(v)s::SMALLINT, %(c)s,
                               %(r)s::SMALLINT, %(m)s) AS id""",
        {"u": u, "n": nuit, "o": (deja or {}).get("origine") or "dite", "s": statut,
         "v": a.get("verres"), "c": _heure_du_coucher(nuit, a.get("couche_a")),
         "r": a.get("ressenti"), "m": a.get("commentaire")})
    return {"fait": {"ecartee": "soirée écartée", "racontee": "soirée notée",
                     "probable": "soirée annoncée : je demanderai au réveil"}[statut],
            "nuit": nuit, "id_soiree": ligne["id"]}


# ---------------------------------------------------------------------------
# La météo
# ---------------------------------------------------------------------------

def lire_meteo(u: int, a: dict) -> object:
    jour = _jour(a["jour"], "jour") if a.get("jour") else aujourd_hui()
    point = None
    if a.get("id_occurrence"):
        s = meteo.seances_dehors(u, datetime.combine(jour - timedelta(days=60), time(0),
                                                      fuseau()),
                                 datetime.combine(jour + timedelta(days=60), time(0), fuseau()))
        point = next((x for x in s if x["id_occurrence"] == a["id_occurrence"]), None)
        if point:
            jour = point["debut"].astimezone(fuseau()).date()
    if point is None and a.get("id_lieu_connu"):
        point = un_seul("SELECT nom AS point, latitude, longitude FROM lieux_du_compte(%(u)s) "
                        "WHERE id_lieu_connu = %(l)s", {"u": u, "l": a["id_lieu_connu"]})
    if point is None:
        point = un_seul("SELECT nom AS point, latitude, longitude FROM lieu_connu "
                        "WHERE id_lieu_connu = lieu_ou_l_on_sera(%(u)s, %(j)s)",
                        {"u": u, "j": jour})
    if point is None or point.get("latitude") is None:
        raise _refus()("sans_lieu", "Aucun point pour la météo : ni la séance, ni le lieu, ni "
                                    "le foyer n'ont d'adresse")
    if not 0 <= (jour - aujourd_hui()).days <= meteo.JOURS_D_AVANCE - 1:
        raise _refus()("requete_invalide", "La prévision va d'aujourd'hui à sept jours")
    heures = meteo.journee(point["latitude"], point["longitude"], jour,
                           maintenant() if jour == aujourd_hui() else None)
    if heures is None:
        raise _refus()("meteo_muette", "Open-Meteo ne répond pas : réessaie plus tard (MTO-10)")
    return {"ou": point["point"], "jour": clair(jour), "heures": heures}


# ---------------------------------------------------------------------------
# Les déclarations
# ---------------------------------------------------------------------------

NATURES = list(lieux.NATURES)
MODES = list(lieux.MODES)

SCHEMA_NOTER_LIEU = _objet({
    "nom": {"type": "string", "description": "Le nom du lieu tel que l'utilisateur le dit"},
    "adresse": {"type": "string", "description": "L'adresse, avec le numéro et la rue"},
    "ici": {"type": "boolean",
            "description": "Vrai : le lieu est là où l'utilisateur se trouve maintenant"},
    "nature": {"type": "string", "enum": NATURES,
               "description": "sejour : un lieu où il dort (chez ses parents)"},
    "rayon_m": {"type": "integer", "minimum": 30, "maximum": 500},
    "mode_trajet": {"type": "string", "enum": MODES,
                    "description": "Comment cet utilisateur y va"},
    "id_lieu_sport": {"type": "integer",
                      "description": "Le lieu de sport dont c'est l'adresse (id_lieu)"},
    "id_lieu_connu": {"type": "integer", "description": "Le lieu connu à mettre à jour"},
    "description": {"type": "string",
                    "description": "Toute la description du lieu, réécrite (ADR-11)"}})

DESCRIPTION_NOTER_LIEU = (
    "Crée ou met à jour un lieu connu : son adresse (cherchée à la Géoplateforme) ou "
    "« ici », sa nature, son rayon, le mode de trajet de l'utilisateur pour y aller, et sa "
    "description. Un lieu de nature sport (une salle, une piscine) devient un lieu où placer "
    "des séances, pour toutes les disciplines. Un lieu existant se retrouve par son nom ou "
    "id_lieu_connu. Les trajets se recalculent. Répète l'adresse trouvée.")

SCHEMA_DESCRIPTION = _objet({
    "id_lieu_connu": {"type": "integer"},
    "texte": {"type": "string",
              "description": "Toute la description du lieu, réécrite, 1 000 caractères au "
                             "plus ; vide : effacée"}}, ["id_lieu_connu", "texte"])

DESCRIPTION_DESCRIPTION = (
    "Écrit la description d'un lieu pour l'utilisateur : ce qu'il y fait, ce qu'il y "
    "préfère, les horaires qui comptent, l'affluence (« ouverte 24 h sur 24, mes séances de "
    "muscu » ; « plus proche mais blindée, plutôt cardio et tapis » ; « chez mes parents : "
    "repos »). C'est elle qui te fait choisir le lieu d'une séance. Réécris tout le texte, en "
    "gardant ce qui vaut encore.")

SCHEMA_SOIREE = _objet({
    "nuit": {"type": "string", "description": "AAAA-MM-JJ, le jour où la soirée commence. "
                                              "Sans : hier le matin, ce soir l'après-midi"},
    "verres": {"type": "integer", "minimum": 0, "maximum": 40,
               "description": "Verres d'alcool"},
    "couche_a": {"type": "string", "description": "HH:MM"},
    "ressenti": {"type": "integer", "minimum": 1, "maximum": 5,
                 "description": "1 au plus mal, 5 en forme"},
    "commentaire": {"type": "string"},
    "pas_une_soiree": {"type": "boolean",
                       "description": "Vrai : ce n'était pas une soirée (dîner, concert sans "
                                      "boire, nuit chez un ami)"}})

DESCRIPTION_SOIREE = (
    "Note une soirée : annoncée (« je suis en soirée »), racontée (verres, heure du "
    "coucher, ressenti), ou écartée. Ce qui n'est pas donné ne remplace rien.")

SCHEMA_METEO = _objet({
    "jour": {"type": "string", "description": "AAAA-MM-JJ, d'aujourd'hui à dans sept jours"},
    "id_occurrence": {"type": "integer", "description": "Au point de cette séance"},
    "id_lieu_connu": {"type": "integer", "description": "Au point de ce lieu"}})

DESCRIPTION_METEO = (
    "La prévision heure par heure d'un jour, de 7 h à 22 h : température, ressenti, pluie, "
    "vent. Au point d'une séance, d'un lieu, ou là où l'utilisateur sera ce jour-là.")


def outils(auteur: str, famille_lieux: str = "lieux") -> tuple:
    """Les outils des lieux, pour un HAL : `auteur` signe les descriptions écrites."""
    from api.coach.outils import Outil
    return (
        Outil("lire_lieux", famille_lieux,
              "Les lieux connus de l'utilisateur : adresse, nature, mode, description, trajets "
              "calculés depuis ses lieux de départ ; et où il est maintenant.",
              _objet({}), lire_lieux),
        Outil("noter_lieu", famille_lieux, DESCRIPTION_NOTER_LIEU, SCHEMA_NOTER_LIEU,
              noter_lieu(auteur)),
        Outil("ecrire_description_lieu", famille_lieux, DESCRIPTION_DESCRIPTION,
              SCHEMA_DESCRIPTION, ecrire_description_lieu(auteur)),
    )


def outils_sport() -> tuple:
    from api.coach.outils import Outil
    return (
        *outils("coach"),
        Outil("noter_soiree", "soiree", DESCRIPTION_SOIREE, SCHEMA_SOIREE, noter_soiree),
        Outil("lire_meteo", "meteo", DESCRIPTION_METEO, SCHEMA_METEO, lire_meteo),
    )
