"""Un exercice hors catalogue, reconnu par son nom                      (EXO-11)

L'utilisateur tape un nom que le catalogue ne connaît pas. Un petit modèle
rapide le lit : soit c'est un exercice du catalogue sous un autre nom
(« bench » pour le développé couché), et c'est celui-là qui sert ; soit il en
déduit le groupe, le matériel et la mesure, et l'exercice rejoint le catalogue
de ce compte seul. Le coach le voit ensuite comme les autres.

Le modèle ne fait que proposer : chaque valeur est vérifiée contre les listes
de la base avant d'écrire quoi que ce soit.
"""

import json
import logging
import re

from api.base import executer, lister, un_seul
from api.coach import modele
from api.config import configuration

LOG = logging.getLogger(__name__)

# L'utilisateur attend devant l'écran d'ajout.
DELAI_RECONNAISSANCE = 20.0
TOKENS_RECONNAISSANCE = 300

# Les valeurs que la table `exercice` accepte (migration 052).
DISCIPLINES = ("musculation", "course", "cardio")
GROUPES = ("pectoraux", "dos", "epaules", "biceps", "triceps", "avant_bras", "abdominaux",
           "lombaires", "fessiers", "quadriceps", "ischios", "adducteurs", "mollets", "cardio")
MATERIELS = ("machine", "poulie", "halteres", "barre", "poids_du_corps", "cardio", "aucun")
MESURES = ("charge_reps", "duree", "distance")

CONSIGNE = """Tu reconnais un exercice de sport d'après le nom qu'un utilisateur a tapé \
dans son appli d'entraînement, faute de le trouver dans le catalogue.

Si ce nom désigne un exercice du catalogue ci-dessous (même mouvement, même \
matériel, même s'il est écrit autrement ou dans une autre langue), rends son code :
{{"code": "developpe_couche_barre"}}

Sinon, décris-le :
{{"libelle": "Hip thrust à la Smith", "discipline": "musculation",
 "groupe_principal": "fessiers", "groupes_secondaires": ["ischios"],
 "materiel": "machine", "unilateral": false, "mesure": "charge_reps",
 "consigne": "Une phrase sur l'exécution."}}

Le libellé reprend le nom tapé, en français correct, avec une majuscule, sans rien \
inventer. Valeurs permises :
- discipline : {disciplines}
- groupe_principal et groupes_secondaires : {groupes}
- materiel : {materiels}
- mesure : charge_reps (charge et répétitions), duree (gainage, planche), \
distance (rameur, course)

Si ce n'est pas un exercice de sport, rends {{"inconnu": "la raison, en une phrase"}}.

Rends le JSON seul.

Catalogue (code | libellé) :
{catalogue}"""


class ExerciceNonReconnu(Exception):
    """Le nom ne désigne pas un exercice, ou le modèle n'a pas répondu."""


def _catalogue_commun() -> list[dict]:
    return lister("SELECT code, libelle FROM exercice WHERE actif AND id_utilisateur IS NULL "
                  "ORDER BY discipline, libelle", {})


def _deja_connu(id_utilisateur: int, libelle: str) -> int | None:
    """Le même nom, au catalogue commun ou déjà ajouté par ce compte : pas d'appel."""
    ligne = un_seul(
        """SELECT id_exercice FROM exercice
            WHERE actif AND lower(libelle) = lower(%(l)s)
              AND (id_utilisateur IS NULL OR id_utilisateur = %(u)s)
            ORDER BY id_utilisateur NULLS FIRST LIMIT 1""",
        {"u": id_utilisateur, "l": libelle})
    return ligne["id_exercice"] if ligne else None


def lire_la_reponse(texte: str) -> dict:
    """Le JSON du modèle, même entouré d'une phrase ou d'un bloc de code."""
    trouve = re.search(r"\{.*\}", texte or "", re.DOTALL)
    if not trouve:
        raise ExerciceNonReconnu("HAL n'a pas su reconnaître cet exercice")
    try:
        rendu = json.loads(trouve.group(0))
    except json.JSONDecodeError:
        raise ExerciceNonReconnu("HAL n'a pas su reconnaître cet exercice") from None
    if not isinstance(rendu, dict):
        raise ExerciceNonReconnu("HAL n'a pas su reconnaître cet exercice")
    return rendu


def verifier(rendu: dict, libelle: str, discipline: str | None) -> dict:
    """Les champs d'un exercice décrit par le modèle, contrôlés un par un."""
    description = {
        "libelle": str(rendu.get("libelle") or libelle).strip()[:100] or libelle,
        "discipline": rendu.get("discipline"),
        "groupe_principal": rendu.get("groupe_principal"),
        "groupes_secondaires": [g for g in rendu.get("groupes_secondaires") or []
                                if g in GROUPES and g != rendu.get("groupe_principal")],
        "materiel": rendu.get("materiel"),
        "unilateral": rendu.get("unilateral") is True,
        "mesure": rendu.get("mesure"),
        "consigne": str(rendu.get("consigne") or "").strip() or None,
    }
    if (description["discipline"] not in DISCIPLINES
            or description["groupe_principal"] not in GROUPES
            or description["materiel"] not in MATERIELS
            or description["mesure"] not in MESURES):
        LOG.info("Exercice mal décrit par le modèle : %s", rendu)
        raise ExerciceNonReconnu("HAL n'a pas su reconnaître cet exercice")
    # Ajouté depuis une séance de musculation, il en est : la base refuserait de
    # mettre un exercice de cardio dans cette séance (EXO-5).
    if discipline and description["discipline"] != discipline:
        description["discipline"] = discipline
    return description


def reconnaitre(id_utilisateur: int, libelle: str, discipline: str | None = None) -> int:
    """EXO-11 : l'id de l'exercice que désigne ce nom, ajouté au besoin.

    Lève ExerciceNonReconnu si le nom n'est pas un exercice, ou si aucun
    fournisseur n'a répondu.
    """
    libelle = " ".join((libelle or "").split())
    if not libelle:
        raise ExerciceNonReconnu("Donne un nom à l'exercice")
    connu = _deja_connu(id_utilisateur, libelle)
    if connu is not None:
        return connu

    catalogue = _catalogue_commun()
    systeme = CONSIGNE.format(
        disciplines=", ".join(DISCIPLINES), groupes=", ".join(GROUPES),
        materiels=", ".join(MATERIELS),
        catalogue="\n".join(f"{x['code']} | {x['libelle']}" for x in catalogue))
    texte = f"Le nom tapé : {libelle[:100]}"
    if discipline:
        texte += f"\nAjouté depuis une séance de {discipline}."

    # FOU-15 : par l'API du compte ou du serveur ; Claude Code démarre trop lentement.
    from api.coach import fournisseurs
    try:
        tour = fournisseurs.ecrire(id_utilisateur, systeme, texte,
                                   configuration().coach_modele_aiguillage
                                   or configuration().coach_modele,
                                   TOKENS_RECONNAISSANCE, DELAI_RECONNAISSANCE,
                                   abonnement=False)
    except modele.ModeleInjoignable as erreur:
        LOG.info("Exercice non reconnu, modèle injoignable : %s", erreur)
        raise ExerciceNonReconnu("HAL ne répond pas pour l'instant, réessaie plus tard") \
            from None

    rendu = lire_la_reponse(tour.texte)
    if rendu.get("inconnu"):
        raise ExerciceNonReconnu(f"HAL ne reconnaît pas un exercice : {rendu['inconnu']}")
    if rendu.get("code"):
        codes = {x["code"] for x in catalogue}
        if rendu["code"] not in codes:
            raise ExerciceNonReconnu("HAL n'a pas su reconnaître cet exercice")
        return un_seul("SELECT id_exercice FROM exercice WHERE code = %(c)s",
                       {"c": rendu["code"]})["id_exercice"]

    d = verifier(rendu, libelle, discipline)
    return executer(
        """SELECT ajouter_exercice_personnel(%(u)s, %(l)s, %(d)s, %(g)s, %(s)s::TEXT[],
                                            %(m)s, %(uni)s, %(me)s, %(c)s) AS id""",
        {"u": id_utilisateur, "l": d["libelle"], "d": d["discipline"],
         "g": d["groupe_principal"], "s": d["groupes_secondaires"], "m": d["materiel"],
         "uni": d["unilateral"], "me": d["mesure"], "c": d["consigne"]})["id"]
