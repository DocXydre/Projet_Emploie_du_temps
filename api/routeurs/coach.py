"""Le coach sportif : profil, objectifs, plan, séances, santé, mesures, échanges.

Aucune règle métier ici. Chaque route lit une vue ou appelle une fonction SQL,
et ne rend que ce qui appartient à l'appelant. Quand la base refuse, le refus a
une forme fixe : un code stable, un message, et le motif (COA-20).

Les données de santé sont sous `/donnees-sante`, pas sous `/sante` : la sonde
d'infrastructure, qui répond sans clé, ne voisine pas avec les données les plus
sensibles du système.
"""

import logging
import threading
from datetime import date, datetime, time, timedelta
from typing import Literal
from uuid import UUID

import psycopg
from fastapi import APIRouter, HTTPException, Query
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from api.base import connexion, executer, lister, un_seul
from api.coach import appel, contexte, outils, planifie, reponse, sante
from api.coach.clair import aujourd_hui, clair, fuseau, lundi_de
from api.erreurs import refus_coach
from api.securite import Administrateur, Authentifie

LOG = logging.getLogger(__name__)

routeur = APIRouter()

Discipline = Literal["musculation", "course", "cardio"]


# ---------------------------------------------------------------------------
# Ce qui sert à plusieurs routes
# ---------------------------------------------------------------------------

def _refuser(code: str, message: str, statut: int = 409) -> HTTPException:
    return HTTPException(status_code=statut, detail={"code": code, "message": message})


def _exiger_coach(id_utilisateur: int) -> None:
    """COA-1 : un compte sans coach n'a ni plan ni synthèse."""
    ligne = un_seul("SELECT coach_actif FROM utilisateur WHERE id_utilisateur = %(u)s",
                    {"u": id_utilisateur})
    if not ligne or not ligne["coach_actif"]:
        raise _refuser("coach_inactif", "Le coach n'est pas activé pour ce compte", 403)


def demander_au_coach(id_utilisateur: int, moment: str, texte: str | None = None,
                      id_occurrence: int | None = None, cle_client: UUID | None = None,
                      precision: str | None = None, deja_affichee: bool = False) -> dict:
    """Un appel à la demande : l'API ne répond qu'une fois le coach terminé (COA-16)."""
    try:
        return appel.appeler_coach(appel.Demande(
            id_utilisateur=id_utilisateur, moment=moment, declencheur="utilisateur",
            texte=texte, id_occurrence=id_occurrence,
            cle_client=str(cle_client) if cle_client else None,
            precision=precision, deja_affichee=deja_affichee))
    except appel.CoachInactif:
        raise _refuser("coach_inactif", "Le coach n'est pas activé pour ce compte",
                       403) from None


def lancer_le_plan(id_utilisateur: int, precision: str | None = None) -> bool:
    """Opération C3 : la construction du plan, sans faire attendre l'appelant.

    Elle prend plusieurs minutes et jusqu'à trente tours d'outils : bien plus
    que les 90 secondes d'un appel à la demande. Elle part donc en tâche de
    fond, et le plan arrive par message, comme une synthèse.
    """
    if contexte.ce_qui_manque(id_utilisateur) or contexte.pause(id_utilisateur):
        return False

    def construire() -> None:
        try:
            appel.appeler_coach(appel.Demande(
                id_utilisateur=id_utilisateur, moment="plan", declencheur="systeme",
                precision=precision))
        except Exception as erreur:  # noqa: BLE001 - une tâche de fond ne remonte rien
            LOG.warning("Construction du plan impossible : %s", erreur)
            executer(
                "INSERT INTO notification (id_utilisateur, type, contenu) "
                "VALUES (%(u)s, 'coach', %(c)s)",
                {"u": id_utilisateur,
                 "c": "Je n'ai pas réussi à construire ton plan : le coach est resté "
                      "injoignable. Relance avec /plan nouveau."})

    threading.Thread(target=construire, name="coach-plan", daemon=True).start()
    return True


# ---------------------------------------------------------------------------
# Profil et dépistage                                                    (PRO)
# ---------------------------------------------------------------------------

class Profil(BaseModel):
    date_naissance: date
    sexe: Literal["homme", "femme"]
    taille_cm: int = Field(ge=100, le=250)
    niveau_musculation: Literal["debutant", "intermediaire", "avance"]
    niveau_course: Literal["debutant", "intermediaire", "avance"]
    moment_prefere: Literal["matin", "soir", "indifferent"] = "indifferent"
    jours_sans_sport: list[int] = Field(default_factory=list,
                                        description="De 1 (lundi) à 7 (dimanche)")
    accord_complements: bool = False
    regime: str | None = None


# PRO-3 : les sept questions du chapitre 1.2 du dossier, dans l'ordre. Leur
# texte exact est affiché à l'utilisateur.
QUESTIONS_DEPISTAGE = {
    "coeur": "Maladie cardiaque, hypertension, ou douleur dans la poitrine au repos "
             "ou à l'effort ?",
    "vertiges": "Vertiges, pertes d'équilibre ou pertes de connaissance ?",
    "maladie_chronique": "Maladie chronique (diabète, asthme sévère, épilepsie, maladie "
                         "rénale...) ?",
    "traitement": "Traitement médical en cours pour une maladie chronique ?",
    "os_articulations": "Problème osseux, articulaire ou musculaire qui pourrait "
                        "s'aggraver avec l'effort ?",
    "grossesse": "Grossesse ou accouchement récent ?",
    "sedentaire_age": "Sédentaire depuis longtemps et âgé de plus de 45 ans (homme) ou "
                      "55 ans (femme) ?",
}


class Depistage(BaseModel):
    """Soit les sept réponses, soit la date d'un avis médical (PRO-5)."""
    coeur: bool | None = None
    vertiges: bool | None = None
    maladie_chronique: bool | None = None
    traitement: bool | None = None
    os_articulations: bool | None = None
    grossesse: bool | None = None
    sedentaire_age: bool | None = None
    avis_medical_le: date | None = None


@routeur.get("/profil", tags=["Coach : profil"], summary="Mon profil")
def lire_profil(qui: Authentifie) -> dict:
    ligne = contexte.profil(qui.id_utilisateur)
    if ligne is None:
        raise _refuser("profil_incomplet", "Le profil n'est pas encore rempli", 404)
    return ligne


@routeur.put("/profil", tags=["Coach : profil"], summary="Créer ou modifier mon profil")
def ecrire_profil(qui: Authentifie, profil: Profil) -> dict:
    executer(
        """INSERT INTO profil AS p (id_utilisateur, date_naissance, sexe, taille_cm,
                                    niveau_musculation, niveau_course, moment_prefere,
                                    jours_sans_sport, accord_complements, regime)
           VALUES (%(u)s, %(date_naissance)s, %(sexe)s, %(taille_cm)s,
                   %(niveau_musculation)s, %(niveau_course)s, %(moment_prefere)s,
                   %(jours_sans_sport)s::SMALLINT[], %(accord_complements)s, %(regime)s)
           ON CONFLICT (id_utilisateur) DO UPDATE
              SET date_naissance = EXCLUDED.date_naissance, sexe = EXCLUDED.sexe,
                  taille_cm = EXCLUDED.taille_cm,
                  niveau_musculation = EXCLUDED.niveau_musculation,
                  niveau_course = EXCLUDED.niveau_course,
                  moment_prefere = EXCLUDED.moment_prefere,
                  jours_sans_sport = EXCLUDED.jours_sans_sport,
                  accord_complements = EXCLUDED.accord_complements,
                  regime = EXCLUDED.regime, date_maj = CURRENT_DATE""",
        {"u": qui.id_utilisateur, **profil.model_dump()})
    return contexte.profil(qui.id_utilisateur) or {}


@routeur.get("/depistage", tags=["Coach : profil"],
             summary="Mon dernier dépistage, et s'il bloque le plan")
def lire_depistage(qui: Authentifie) -> dict:
    return {"questions": QUESTIONS_DEPISTAGE,
            "dernier": contexte.depistage(qui.id_utilisateur)}


@routeur.post("/depistage", tags=["Coach : profil"],
              summary="Répondre au questionnaire, ou déclarer un avis médical")
def repondre_depistage(qui: Authentifie, reponses: Depistage) -> dict:
    sept = [getattr(reponses, question) for question in QUESTIONS_DEPISTAGE]
    if all(r is None for r in sept):
        if reponses.avis_medical_le is None:
            raise _refuser("requete_invalide",
                           "Donne les sept réponses, ou la date d'un avis médical", 422)
        # PRO-5 : le plan se débloque quand l'utilisateur déclare avoir eu cet avis.
        ligne = executer(
            """UPDATE depistage SET avis_medical_le = %(d)s
                WHERE id_depistage = (SELECT id_depistage FROM depistage
                                       WHERE id_utilisateur = %(u)s
                                       ORDER BY date_reponse DESC, id_depistage DESC LIMIT 1)
                  AND positif
               RETURNING id_depistage""",
            {"u": qui.id_utilisateur, "d": reponses.avis_medical_le})
        if ligne is None:
            raise _refuser("introuvable",
                           "Aucun dépistage positif n'attend d'avis médical", 404)
    elif any(r is None for r in sept):
        raise _refuser("requete_invalide", "Les sept réponses sont obligatoires", 422)
    else:
        executer(
            """INSERT INTO depistage (id_utilisateur, coeur, vertiges, maladie_chronique,
                                      traitement, os_articulations, grossesse,
                                      sedentaire_age, avis_medical_le)
               VALUES (%(u)s, %(coeur)s, %(vertiges)s, %(maladie_chronique)s,
                       %(traitement)s, %(os_articulations)s, %(grossesse)s,
                       %(sedentaire_age)s, %(avis)s)""",
            {"u": qui.id_utilisateur,
             **{q: getattr(reponses, q) for q in QUESTIONS_DEPISTAGE},
             "avis": reponses.avis_medical_le if any(sept) else None})
    return {"dernier": contexte.depistage(qui.id_utilisateur)}


# ---------------------------------------------------------------------------
# Objectifs                                                              (OBJ)
# ---------------------------------------------------------------------------

class NouvelObjectif(BaseModel):
    type: Literal["pilier", "course", "performance", "mesure"]
    libelle: str = Field(min_length=1, max_length=120)
    pilier: Literal["force", "physique", "endurance"] | None = None
    distance_m: int | None = Field(default=None, gt=0)
    cible_valeur: float | None = None
    cible_unite: str | None = Field(default=None, max_length=12)
    exercice: str | None = Field(default=None, description="Code au catalogue")
    type_mesure: str | None = None
    echeance: date | None = None
    principal: bool = False
    rang: int = Field(default=1, gt=0)
    cle_client: UUID | None = None


class ObjectifModifie(BaseModel):
    libelle: str | None = Field(default=None, max_length=120)
    cible_valeur: float | None = None
    cible_unite: str | None = None
    distance_m: int | None = None
    echeance: date | None = None
    rang: int | None = Field(default=None, gt=0)


def _objectif(id_utilisateur: int, id_objectif: int) -> dict:
    for objectif in contexte.objectifs(id_utilisateur):
        if objectif["id_objectif"] == id_objectif:
            return objectif
    raise _refuser("introuvable", "Objectif introuvable", 404)


def _avis_sur(id_utilisateur: int, id_objectif: int, cle_client: UUID | None,
              precision: str) -> dict | None:
    """Opération C2 : l'avis du coach, puis le plan s'il n'y en a pas (OBJ-5)."""
    ligne = un_seul("SELECT coach_actif FROM utilisateur WHERE id_utilisateur = %(u)s",
                    {"u": id_utilisateur})
    if not ligne or not ligne["coach_actif"]:
        return None
    rendu = demander_au_coach(
        id_utilisateur, "faisabilite", cle_client=cle_client,
        precision=f"{precision} L'objectif concerné : id_objectif {id_objectif}.")
    objectif = _objectif(id_utilisateur, id_objectif)
    if objectif["principal"] and objectif["statut"] == "actif" \
            and contexte.plan(id_utilisateur) is None:
        rendu["plan_en_construction"] = lancer_le_plan(id_utilisateur)
        manques = contexte.ce_qui_manque(id_utilisateur)
        if manques:
            rendu["plan_en_attente_de"] = manques
    return rendu


@routeur.get("/objectifs", tags=["Coach : objectifs"], summary="Mes objectifs, par rang")
def lister_objectifs(qui: Authentifie, statut: str | None = None) -> list[dict]:
    return contexte.objectifs(qui.id_utilisateur, statut)


@routeur.post("/objectifs", tags=["Coach : objectifs"], status_code=201,
              summary="Créer un objectif, et demander l'avis du coach")
def creer_objectif(qui: Authentifie, objectif: NouvelObjectif) -> dict:
    id_exercice = None
    if objectif.exercice:
        ligne = un_seul("SELECT id_exercice FROM exercice WHERE code = %(c)s AND actif",
                        {"c": objectif.exercice})
        if ligne is None:
            raise _refuser("introuvable", "Exercice inconnu au catalogue", 404)
        id_exercice = ligne["id_exercice"]

    if objectif.principal:
        # OBJ-2 : un seul principal actif. Le précédent redevient secondaire.
        executer("UPDATE objectif SET principal = FALSE "
                 "WHERE id_utilisateur = %(u)s AND principal AND statut = 'actif'",
                 {"u": qui.id_utilisateur})
    cree = executer(
        """INSERT INTO objectif (id_utilisateur, type, libelle, pilier, distance_m,
                                 cible_valeur, cible_unite, id_exercice, type_mesure,
                                 echeance, principal, rang)
           VALUES (%(u)s, %(type)s, %(libelle)s, %(pilier)s, %(distance_m)s,
                   %(cible_valeur)s, %(cible_unite)s, %(e)s, %(type_mesure)s,
                   %(echeance)s, %(principal)s, %(rang)s)
           RETURNING id_objectif""",
        {"u": qui.id_utilisateur, "e": id_exercice,
         **objectif.model_dump(exclude={"exercice", "cle_client"})})
    avis = _avis_sur(qui.id_utilisateur, cree["id_objectif"], objectif.cle_client,
                     "L'utilisateur vient de créer cet objectif.")
    return {"objectif": _objectif(qui.id_utilisateur, cree["id_objectif"]), "coach": avis}


@routeur.patch("/objectifs/{id_objectif}", tags=["Coach : objectifs"],
               summary="Modifier la cible, l'échéance ou le rang")
def modifier_objectif(qui: Authentifie, id_objectif: int, champs: ObjectifModifie) -> dict:
    avant = _objectif(qui.id_utilisateur, id_objectif)
    voulus = champs.model_dump(exclude_unset=True)
    if voulus:
        # Les noms de colonnes viennent du modèle ci-dessus, jamais de la requête.
        affectations = ", ".join(f"{colonne} = %({colonne})s" for colonne in voulus)
        executer(f"UPDATE objectif SET {affectations} "
                 "WHERE id_objectif = %(o)s AND id_utilisateur = %(u)s",
                 {**voulus, "o": id_objectif, "u": qui.id_utilisateur})
    avis = None
    # OBJ-5 : l'avis est redemandé quand la cible ou l'échéance change.
    if any(cle in voulus and voulus[cle] != avant.get(cle)
           for cle in ("cible_valeur", "echeance", "distance_m")):
        avis = _avis_sur(qui.id_utilisateur, id_objectif, None,
                         "L'utilisateur vient de modifier la cible ou l'échéance.")
    return {"objectif": _objectif(qui.id_utilisateur, id_objectif), "coach": avis}


@routeur.post("/objectifs/{id_objectif}/principal", tags=["Coach : objectifs"],
              summary="En faire l'objectif principal")
def designer_principal(qui: Authentifie, id_objectif: int) -> dict:
    objectif = _objectif(qui.id_utilisateur, id_objectif)
    if objectif["statut"] != "actif":
        raise _refuser("regle_metier", "Seul un objectif actif peut devenir le principal")
    executer("UPDATE objectif SET principal = (id_objectif = %(o)s) "
             "WHERE id_utilisateur = %(u)s AND statut = 'actif'",
             {"o": id_objectif, "u": qui.id_utilisateur})
    # PLN-2 : le plan est reconstruit quand le principal change.
    en_construction = False
    if not objectif["principal"]:
        en_construction = lancer_le_plan(
            qui.id_utilisateur, "L'objectif principal vient de changer : le plan est à "
                                "reconstruire autour du nouveau.")
    return {"objectif": _objectif(qui.id_utilisateur, id_objectif),
            "plan_en_construction": en_construction}


def _changer_statut(qui, id_objectif: int, statut: str, depuis: tuple[str, ...]) -> dict:
    ligne = executer(
        """UPDATE objectif
              SET statut = %(s)s,
                  date_cloture = CASE WHEN %(s)s IN ('atteint', 'abandonne')
                                      THEN CURRENT_DATE END
            WHERE id_objectif = %(o)s AND id_utilisateur = %(u)s
              AND statut = ANY (%(d)s::TEXT[])
           RETURNING id_objectif""",
        {"s": statut, "o": id_objectif, "u": qui.id_utilisateur, "d": list(depuis)})
    if ligne is None:
        _objectif(qui.id_utilisateur, id_objectif)
        raise _refuser("objectif_clos", "Cet objectif ne peut pas passer à cet état")
    return _objectif(qui.id_utilisateur, id_objectif)


@routeur.post("/objectifs/{id_objectif}/pause", tags=["Coach : objectifs"],
              summary="Mettre en pause")
def suspendre_objectif(qui: Authentifie, id_objectif: int) -> dict:
    return _changer_statut(qui, id_objectif, "en_pause", ("actif",))


@routeur.post("/objectifs/{id_objectif}/reprendre", tags=["Coach : objectifs"],
              summary="Reprendre")
def reprendre_objectif(qui: Authentifie, id_objectif: int) -> dict:
    objectif = _objectif(qui.id_utilisateur, id_objectif)
    if objectif["principal"] and un_seul(
            "SELECT 1 FROM objectif WHERE id_utilisateur = %(u)s AND principal "
            "AND statut = 'actif'", {"u": qui.id_utilisateur}):
        # OBJ-2 : un autre est devenu le principal entre-temps.
        executer("UPDATE objectif SET principal = FALSE WHERE id_objectif = %(o)s",
                 {"o": id_objectif})
    return _changer_statut(qui, id_objectif, "actif", ("en_pause",))


@routeur.post("/objectifs/{id_objectif}/clore", tags=["Coach : objectifs"],
              summary="Clore, atteint ou abandonné")
def clore_objectif(qui: Authentifie, id_objectif: int, atteint: bool = True) -> dict:
    return _changer_statut(qui, id_objectif, "atteint" if atteint else "abandonne",
                           ("actif", "en_pause"))


# ---------------------------------------------------------------------------
# Plan                                                                   (PLN)
# ---------------------------------------------------------------------------

def semaine(id_utilisateur: int, lundi: date) -> dict:
    return outils.lire_semaine(id_utilisateur, {"lundi": lundi.isoformat()})


@routeur.get("/plan", tags=["Coach : plan"],
             summary="Le plan en cours : trame et quatre semaines")
def lire_plan(qui: Authentifie) -> dict:
    plan = contexte.plan(qui.id_utilisateur)
    principal = next((o for o in contexte.objectifs(qui.id_utilisateur)
                      if o["principal"] and o["statut"] == "actif"), None)
    return {"plan": plan,
            "objectif_principal": principal,
            "feuille_de_route": principal["feuille_de_route"] if principal else None,
            "pause": contexte.pause(qui.id_utilisateur),
            "manque": contexte.ce_qui_manque(qui.id_utilisateur) if plan is None else []}


@routeur.get("/plan/semaine", tags=["Coach : plan"],
             summary="Les séances d'une semaine, avec leur état")
def lire_semaine(qui: Authentifie, lundi: date | None = None) -> dict:
    return semaine(qui.id_utilisateur, lundi_de(lundi or aujourd_hui()))


@routeur.post("/plan/semaine/valider", tags=["Coach : plan"], summary="Valider la semaine")
def valider_semaine(qui: Authentifie, lundi: date | None = None) -> dict:
    jour = lundi_de(lundi or aujourd_hui())
    ligne = executer("SELECT valider_semaine(%(u)s, %(l)s) AS n",
                     {"u": qui.id_utilisateur, "l": jour})
    return {"validees": ligne["n"], **semaine(qui.id_utilisateur, jour)}


@routeur.post("/plan/reconstruire", tags=["Coach : plan"], summary="Demander un nouveau plan")
def reconstruire_plan(qui: Authentifie, pseudo: str | None = None) -> dict:
    cible = qui.id_utilisateur
    if pseudo and pseudo != qui.pseudo:
        # Reconstruire le plan d'un autre compte est réservé à l'administrateur.
        if not qui.est_admin:
            raise _refuser("non_autorise", "Réservé à l'administrateur", 403)
        autre = un_seul("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %(p)s",
                        {"p": pseudo})
        if autre is None:
            raise _refuser("introuvable", "Compte inconnu", 404)
        cible = autre["id_utilisateur"]
    _exiger_coach(cible)
    manques = contexte.ce_qui_manque(cible)
    if manques:
        code = "profil_incomplet" if "profil" in manques[0] else (
            "depistage_requis" if "dépistage" in manques[0] or "épistage" in manques[0]
            else "regle_metier")
        raise _refuser(code, "Le plan ne peut pas être construit : " + " ; ".join(manques))
    if contexte.pause(cible):
        raise _refuser("coach_en_pause", "Le coach est en pause : lève-la d'abord")
    lancer_le_plan(cible, "L'utilisateur demande un nouveau plan.")
    return {"plan_en_construction": True,
            "message": "Le coach construit le plan. Il arrive par message dans quelques "
                       "minutes."}


# ---------------------------------------------------------------------------
# Séances                                                       (PLN, LIB, SAI)
# ---------------------------------------------------------------------------

class SeanceLibre(BaseModel):
    discipline: Discipline
    debut: datetime | None = Field(default=None, description="Maintenant par défaut")
    duree_minutes: int = Field(default=60, ge=15, le=240)
    id_lieu: int | None = None
    texte: str | None = Field(default=None, description="Ce qu'on compte faire")
    cle_client: UUID


class Serie(BaseModel):
    id_exercice: int | None = None
    code: str | None = Field(default=None, description="À la place de id_exercice")
    cle_client: UUID
    numero: int | None = Field(default=None, gt=0)
    charge_kg: float | None = Field(default=None, ge=0)
    repetitions: int | None = Field(default=None, ge=0)
    duree_secondes: int | None = Field(default=None, gt=0)
    distance_m: int | None = Field(default=None, gt=0)
    marge_repetitions: int | None = Field(default=None, ge=0, le=5)
    saisie_le: datetime | None = None
    id_seance_exercice: int | None = None


class SerieCorrigee(BaseModel):
    charge_kg: float | None = Field(default=None, ge=0)
    repetitions: int | None = Field(default=None, ge=0)
    duree_secondes: int | None = Field(default=None, gt=0)
    distance_m: int | None = Field(default=None, gt=0)
    marge_repetitions: int | None = Field(default=None, ge=0, le=5)


class Bilan(BaseModel):
    effort: int = Field(ge=1, le=10)
    duree_minutes: int | None = Field(default=None, gt=0)
    commentaire: str | None = None
    cle_client: UUID | None = None


class Deplacement(BaseModel):
    debut: datetime | None = None
    id_lieu: int | None = None


class Remplacement(BaseModel):
    id_seance_exercice: int
    id_exercice: int


def _detail(id_utilisateur: int, id_occurrence: int) -> dict:
    detail = outils.detail_seance(id_utilisateur, id_occurrence)
    if detail is None:
        raise _refuser("introuvable", "Séance introuvable", 404)
    return detail


@routeur.get("/seances/aujourd-hui", tags=["Coach : séances"],
             summary="Les séances du jour, à charger d'avance")
def seances_du_jour(qui: Authentifie) -> list[dict]:
    """SAI-10 : la séance du jour, ses exercices et leurs alternatives permises."""
    lignes = lister(
        "SELECT id_occurrence FROM v_seance_coach WHERE id_utilisateur = %(u)s "
        "AND jour = jour_de(now()) AND discipline IS NOT NULL ORDER BY debut NULLS LAST",
        {"u": qui.id_utilisateur})
    return [_detail(qui.id_utilisateur, ligne["id_occurrence"]) for ligne in lignes]


@routeur.post("/seances/libre", tags=["Coach : séances"], status_code=201,
              summary="Saisir une séance libre, faite ou en cours")
def ouvrir_seance_libre(qui: Authentifie, seance: SeanceLibre) -> dict:
    ligne = executer(
        "SELECT creer_seance_libre(%(u)s, %(d)s, COALESCE(%(debut)s, now()), %(duree)s, "
        "%(lieu)s, FALSE, %(cle)s) AS id",
        {"u": qui.id_utilisateur, "d": seance.discipline, "debut": seance.debut,
         "duree": seance.duree_minutes, "lieu": seance.id_lieu, "cle": seance.cle_client})
    return _detail(qui.id_utilisateur, ligne["id"])


@routeur.post("/seances/libre/annoncer", tags=["Coach : séances"], status_code=201,
              summary="Annoncer une séance libre à venir")
def annoncer_seance_libre(qui: Authentifie, seance: SeanceLibre) -> dict:
    if seance.debut is None:
        raise _refuser("requete_invalide", "Une annonce donne le jour et l'heure", 422)
    ligne = executer(
        "SELECT creer_seance_libre(%(u)s, %(d)s, %(debut)s, %(duree)s, %(lieu)s, TRUE, "
        "%(cle)s) AS id",
        {"u": qui.id_utilisateur, "d": seance.discipline, "debut": seance.debut,
         "duree": seance.duree_minutes, "lieu": seance.id_lieu, "cle": seance.cle_client})
    # LIB-4 : une annonce déclenche un appel immédiat, comme un signalement.
    rendu = demander_au_coach(
        qui.id_utilisateur, "signalement", texte=seance.texte, id_occurrence=ligne["id"],
        cle_client=seance.cle_client,
        precision="L'utilisateur annonce une séance libre, qu'il fera à sa façon. Dis-lui "
                  "ce que tu conseilles d'éviter ce jour-là, et ajuste la suite de la "
                  "semaine sans attendre. Tu ne la refuses pas.")
    return {"seance": _detail(qui.id_utilisateur, ligne["id"]), "coach": rendu}


@routeur.get("/seances/{id_occurrence}", tags=["Coach : séances"],
             summary="Contenu, alternatives permises, séries saisies")
def lire_seance(qui: Authentifie, id_occurrence: int) -> dict:
    return _detail(qui.id_utilisateur, id_occurrence)


@routeur.post("/seances/{id_occurrence}/liberer", tags=["Coach : séances"],
              summary="Faire autre chose à la place de la séance prévue")
def liberer_seance(qui: Authentifie, id_occurrence: int) -> dict:
    executer("SELECT liberer_seance(%(u)s, %(o)s)",
             {"u": qui.id_utilisateur, "o": id_occurrence})
    return _detail(qui.id_utilisateur, id_occurrence)


@routeur.post("/seances/{id_occurrence}/valider", tags=["Coach : séances"],
              summary="Valider une séance proposée, seule")
def valider_seance(qui: Authentifie, id_occurrence: int) -> dict:
    executer("SELECT valider_seance(%(u)s, %(o)s)",
             {"u": qui.id_utilisateur, "o": id_occurrence})
    return _detail(qui.id_utilisateur, id_occurrence)


@routeur.post("/seances/{id_occurrence}/deplacer", tags=["Coach : séances"],
              summary="Déplacer une séance, ou en changer le lieu")
def deplacer_seance(qui: Authentifie, id_occurrence: int, deplacement: Deplacement) -> dict:
    """PLN-12 : si une règle de sécurité est enfreinte, l'opération se fait et la
    réponse porte un champ `avertissements`."""
    ligne = executer("SELECT deplacer_seance(%(u)s, %(o)s, %(d)s, %(l)s) AS rendu",
                     {"u": qui.id_utilisateur, "o": id_occurrence,
                      "d": deplacement.debut, "l": deplacement.id_lieu})
    return {**_detail(qui.id_utilisateur, id_occurrence),
            "avertissements": ligne["rendu"]["avertissements"]}


@routeur.delete("/seances/{id_occurrence}", tags=["Coach : séances"],
                summary="Supprimer une séance")
def supprimer_seance(qui: Authentifie, id_occurrence: int) -> dict:
    """Une séance proposée que l'on supprime n'est pas comptée comme manquée."""
    executer("SELECT supprimer_seance_sport(%(u)s, %(o)s)",
             {"u": qui.id_utilisateur, "o": id_occurrence})
    return {"supprimee": id_occurrence}


def _id_exercice(serie: Serie) -> int | None:
    if serie.id_exercice is not None:
        return serie.id_exercice
    ligne = un_seul("SELECT id_exercice FROM exercice WHERE code = %(c)s", {"c": serie.code})
    return ligne["id_exercice"] if ligne else None


@routeur.post("/seances/{id_occurrence}/series", tags=["Coach : séances"],
              summary="Enregistrer une ou plusieurs séries")
def enregistrer_series(qui: Authentifie, id_occurrence: int,
                       series: list[Serie] | Serie) -> dict:
    """SAI-11 : un envoi groupé, dans n'importe quel ordre. La réponse dit, pour
    chaque clé reçue, si elle a été créée, si elle existait déjà, ou pourquoi
    elle est refusée. Un refus sur une ligne ne fait pas échouer les autres."""
    liste = series if isinstance(series, list) else [series]
    resultats = []
    for serie in liste:
        exercice = _id_exercice(serie)
        if exercice is None:
            resultats.append({"cle_client": str(serie.cle_client), "etat": "refusee",
                              "code": "introuvable", "message": "Exercice inconnu"})
            continue
        try:
            ligne = executer(
                """SELECT enregistrer_serie(%(u)s, %(o)s, %(e)s, %(cle)s, %(numero)s,
                          %(charge)s::NUMERIC, %(reps)s, %(duree)s, %(distance)s, %(marge)s,
                          %(quand)s, %(prevue)s) AS rendu""",
                {"u": qui.id_utilisateur, "o": id_occurrence, "e": exercice,
                 "cle": serie.cle_client, "numero": serie.numero,
                 "charge": serie.charge_kg, "reps": serie.repetitions,
                 "duree": serie.duree_secondes, "distance": serie.distance_m,
                 "marge": serie.marge_repetitions, "quand": serie.saisie_le,
                 "prevue": serie.id_seance_exercice})
            resultats.append({"cle_client": str(serie.cle_client), **ligne["rendu"]})
        except psycopg.Error as erreur:
            refus = refus_coach(erreur)
            if refus is None and not (erreur.sqlstate or "").startswith("23"):
                raise
            resultats.append({
                "cle_client": str(serie.cle_client), "etat": "refusee",
                "code": refus["code"] if refus else "regle_metier",
                "message": refus["message"] if refus
                else (erreur.diag.message_primary or "Série refusée")})
    return {"series": resultats}


def _serie_de(qui, id_occurrence: int, id_serie: int) -> None:
    if un_seul(
            """SELECT 1 FROM serie_saisie ss JOIN occurrence o
                   ON o.id_occurrence = ss.id_occurrence
                WHERE ss.id_serie = %(s)s AND ss.id_occurrence = %(o)s
                  AND o.id_utilisateur = %(u)s""",
            {"s": id_serie, "o": id_occurrence, "u": qui.id_utilisateur}) is None:
        raise _refuser("introuvable", "Série introuvable", 404)


@routeur.patch("/seances/{id_occurrence}/series/{id_serie}", tags=["Coach : séances"],
               summary="Corriger une série")
def corriger_serie(qui: Authentifie, id_occurrence: int, id_serie: int,
                   correction: SerieCorrigee) -> dict:
    """SAI-8 : jusqu'à la synthèse du soir. Ensuite la série est figée."""
    _serie_de(qui, id_occurrence, id_serie)
    voulus = correction.model_dump(exclude_unset=True)
    if voulus:
        affectations = ", ".join(f"{colonne} = %({colonne})s" for colonne in voulus)
        executer(f"UPDATE serie_saisie SET {affectations} WHERE id_serie = %(s)s",
                 {**voulus, "s": id_serie})
    return _detail(qui.id_utilisateur, id_occurrence)


@routeur.delete("/seances/{id_occurrence}/series/{id_serie}", tags=["Coach : séances"],
                summary="Supprimer une série")
def supprimer_serie(qui: Authentifie, id_occurrence: int, id_serie: int) -> dict:
    _serie_de(qui, id_occurrence, id_serie)
    executer("DELETE FROM serie_saisie WHERE id_serie = %(s)s", {"s": id_serie})
    return {"supprimee": id_serie}


@routeur.post("/seances/{id_occurrence}/remplacer", tags=["Coach : séances"],
              summary="Remplacer un exercice par une alternative")
def remplacer_exercice(qui: Authentifie, id_occurrence: int,
                       remplacement: Remplacement) -> dict:
    """SAI-3 : changer de machine ne demande aucun appel au modèle. La ligne
    prévue garde ses séries et ses répétitions : les séries saisies ensuite se
    rattachent à elle, avec l'exercice choisi (SAI-2)."""
    detail = _detail(qui.id_utilisateur, id_occurrence)
    prevue = next((p for p in detail["prevu"]
                   if p["id_seance_exercice"] == remplacement.id_seance_exercice), None)
    if prevue is None:
        raise _refuser("introuvable", "Cette ligne n'est pas dans la séance", 404)
    choisie = next((a for a in prevue.get("alternatives", [])
                    if a["id_exercice"] == remplacement.id_exercice), None)
    if choisie is None:
        raise _refuser("exercice_interdit",
                       "Cet exercice ne fait pas partie des alternatives permises")
    return {"ligne_prevue": prevue, "exercice_choisi": choisie,
            "a_saisir_avec": {"id_seance_exercice": prevue["id_seance_exercice"],
                              "id_exercice": choisie["id_exercice"]},
            "note": "Repars d'une charge prudente : les charges ne se transposent pas "
                    "d'un exercice à l'autre."}


@routeur.post("/seances/{id_occurrence}/bilan", tags=["Coach : séances"],
              summary="Clore la séance : effort, durée, commentaire")
def enregistrer_bilan(qui: Authentifie, id_occurrence: int, bilan: Bilan,
                      appeler_coach: bool = False) -> dict:
    duree = bilan.duree_minutes
    if duree is None:
        prevue = un_seul("SELECT duree_minutes FROM seance WHERE id_occurrence = %(o)s",
                         {"o": id_occurrence})
        duree = prevue["duree_minutes"] if prevue else 60
    ligne = executer(
        "SELECT enregistrer_bilan(%(u)s, %(o)s, %(e)s, %(d)s, %(c)s, %(cle)s) AS rendu",
        {"u": qui.id_utilisateur, "o": id_occurrence, "e": bilan.effort, "d": duree,
         "c": bilan.commentaire, "cle": bilan.cle_client})
    rendu = {**ligne["rendu"], "seance": _detail(qui.id_utilisateur, id_occurrence)}
    if appeler_coach:
        # SAI-7 : le bouton « Bilan » n'attend pas 23 h.
        rendu["coach"] = demander_au_coach(
            qui.id_utilisateur, "bilan", texte=bilan.commentaire,
            id_occurrence=id_occurrence, cle_client=bilan.cle_client)
    return rendu


@routeur.post("/seances/{id_occurrence}/pas-faite", tags=["Coach : séances"],
              summary="Déclarer la séance pas faite")
def declarer_pas_faite(qui: Authentifie, id_occurrence: int) -> dict:
    """PLN-10 : close, pas replacée d'office. Le coach en décide à la synthèse."""
    executer("SELECT seance_sport_pas_faite(%(u)s, %(o)s)",
             {"u": qui.id_utilisateur, "o": id_occurrence})
    return {"pas_faite": id_occurrence}


# ---------------------------------------------------------------------------
# Ajustements                                                  (PLN-18, PLN-19)
# ---------------------------------------------------------------------------

@routeur.get("/ajustements", tags=["Coach : séances"],
             summary="Les ajustements en attente de réponse")
def ajustements_en_attente(qui: Authentifie) -> list[dict]:
    return lister(
        """SELECT a.id_ajustement, a.id_occurrence, a.nature, a.motif, a.contenu,
                  a.date_creation, s.jour, s.debut, s.discipline, s.type_seance,
                  s.duree_minutes, s.intensite
             FROM ajustement a JOIN v_seance_coach s ON s.id_occurrence = a.id_occurrence
            WHERE s.id_utilisateur = %(u)s AND a.statut = 'propose'
            ORDER BY s.debut""", {"u": qui.id_utilisateur})


@routeur.post("/ajustements/{id_ajustement}/accepter", tags=["Coach : séances"],
              summary="Accepter la version du coach")
def accepter_ajustement(qui: Authentifie, id_ajustement: int) -> dict:
    ligne = executer("SELECT accepter_ajustement(%(u)s, %(a)s) AS o",
                     {"u": qui.id_utilisateur, "a": id_ajustement})
    return {"accepte": id_ajustement, "id_occurrence": ligne["o"]}


@routeur.post("/ajustements/{id_ajustement}/refuser", tags=["Coach : séances"],
              summary="Garder la séance telle que validée")
def refuser_ajustement(qui: Authentifie, id_ajustement: int) -> dict:
    ligne = executer("SELECT refuser_ajustement(%(u)s, %(a)s) AS o",
                     {"u": qui.id_utilisateur, "a": id_ajustement})
    return {"refuse": id_ajustement, "id_occurrence": ligne["o"]}


# ---------------------------------------------------------------------------
# Données de santé                                                       (SAN)
# ---------------------------------------------------------------------------

class SanteJour(BaseModel):
    pas: int | None = Field(default=None, ge=0)
    fc_repos: int | None = Field(default=None, ge=25, le=150)
    vfc_ms: float | None = Field(default=None, gt=0)
    sommeil_minutes: int | None = Field(default=None, ge=0, le=1440)


class Activite(BaseModel):
    type: str = Field(description="Le nom que lui donne l'application Santé")
    discipline: Literal["musculation", "course", "cardio", "autre"] | None = Field(
        default=None, description="Déduite du type si elle n'est pas donnée")
    debut: datetime
    fin: datetime
    duree_secondes: int | None = Field(default=None, gt=0)
    distance_m: int | None = Field(default=None, ge=0)
    denivele_m: int | None = Field(default=None, ge=0)
    energie_kcal: int | None = Field(default=None, ge=0)
    fc_moyenne: int | None = Field(default=None, ge=25, le=250)
    fc_max: int | None = Field(default=None, ge=25, le=250)
    allure_s_km: int | None = Field(default=None, gt=0)
    cadence: int | None = Field(default=None, gt=0)
    details: dict = Field(default_factory=dict,
                          description="Tout ce que la montre donne d'autre, gardé tel quel")


@routeur.put("/donnees-sante/jours/{jour}", tags=["Coach : santé"],
             summary="Données du jour, insérées ou mises à jour")
def recevoir_jour(qui: Authentifie, jour: date, donnees: SanteJour) -> dict:
    ligne = executer(
        "SELECT recevoir_sante_jour(%(u)s, %(j)s, %(pas)s, %(fc_repos)s, %(vfc_ms)s::NUMERIC, "
        "%(sommeil_minutes)s) AS creee",
        {"u": qui.id_utilisateur, "j": jour, **donnees.model_dump()})
    return {"jour": jour, "creee": ligne["creee"]}


@routeur.put("/donnees-sante/activites/{cle_externe}", tags=["Coach : santé"],
             summary="Séance de la montre, insérée ou mise à jour")
def recevoir_activite(qui: Authentifie, cle_externe: str, activite: Activite) -> dict:
    discipline = activite.discipline or sante.discipline_de(activite.type)
    donnees = activite.model_dump(exclude={"type", "discipline", "debut", "fin"},
                                  exclude_none=True)
    ligne = executer(
        "SELECT recevoir_activite(%(u)s, %(cle)s, %(type)s, %(d)s, %(debut)s, %(fin)s, "
        "%(donnees)s) AS rendu",
        {"u": qui.id_utilisateur, "cle": cle_externe[:64], "type": activite.type,
         "d": discipline, "debut": activite.debut, "fin": activite.fin,
         "donnees": Jsonb(donnees)})
    return {**ligne["rendu"], "discipline": discipline}


@routeur.get("/donnees-sante/fraicheur", tags=["Coach : santé"],
             summary="Date du dernier envoi")
def fraicheur(qui: Authentifie) -> dict:
    return un_seul("SELECT dernier_envoi, dernier_jour FROM v_sante_fraicheur "
                   "WHERE id_utilisateur = %(u)s", {"u": qui.id_utilisateur}) or {}


@routeur.get("/donnees-sante/jours", tags=["Coach : santé"],
             summary="Ce qui a été reçu, pour vérifier un envoi")
def relire_jours(qui: Authentifie, depuis: date | None = None) -> dict:
    """SAN-7 : rendu à son seul propriétaire. Sert à contrôler ce que l'application
    a réellement envoyé."""
    return outils.lire_sante(qui.id_utilisateur, {
        "du": (depuis or aujourd_hui() - timedelta(days=13)).isoformat(),
        "au": aujourd_hui().isoformat()})


# ---------------------------------------------------------------------------
# Mesures                                                                (MES)
# ---------------------------------------------------------------------------

class Mesure(BaseModel):
    type: str
    valeur: float = Field(gt=0)
    unite: str = Field(max_length=12)
    cote: Literal["gauche", "droite"] | None = None
    date_mesure: date | None = None
    exercice: str | None = None


@routeur.get("/mesures", tags=["Coach : mesures"], summary="Historique d'une mesure")
def lire_mesures(qui: Authentifie, type: str | None = None) -> dict:
    return outils.lire_mesures(qui.id_utilisateur, {"type": type})


@routeur.post("/mesures", tags=["Coach : mesures"], status_code=201,
              summary="Saisir une mesure")
def saisir_mesure(qui: Authentifie, mesure: Mesure) -> dict:
    exercice = None
    if mesure.exercice:
        ligne = un_seul("SELECT id_exercice FROM exercice WHERE code = %(c)s",
                        {"c": mesure.exercice})
        exercice = ligne["id_exercice"] if ligne else None
    ligne = executer(
        "SELECT saisir_mesure(%(u)s, %(t)s, %(v)s::NUMERIC, %(un)s, %(c)s, %(d)s, %(e)s) AS id",
        {"u": qui.id_utilisateur, "t": mesure.type, "v": mesure.valeur,
         "un": mesure.unite, "c": mesure.cote, "d": mesure.date_mesure, "e": exercice})
    return {"id_mesure": ligne["id"]}


@routeur.get("/mesures/fenetres", tags=["Coach : mesures"], summary="Fenêtres ouvertes")
def fenetres_ouvertes(qui: Authentifie) -> list[dict]:
    return lister(
        """SELECT id_fenetre, type_mesure, lower(periode) AS du, upper(periode) - 1 AS au,
                  consigne FROM fenetre_mesure
            WHERE id_utilisateur = %(u)s AND statut = 'ouverte' ORDER BY lower(periode)""",
        {"u": qui.id_utilisateur})


@routeur.post("/mesures/fenetres/{id_fenetre}/reporter", tags=["Coach : mesures"],
              summary="Dire qu'on ne peut pas maintenant")
def reporter_fenetre(qui: Authentifie, id_fenetre: int) -> dict:
    executer("SELECT reporter_fenetre(%(u)s, %(f)s)",
             {"u": qui.id_utilisateur, "f": id_fenetre})
    return {"reportee": id_fenetre}


# ---------------------------------------------------------------------------
# Le coach lui-même                                                 (COA, PAU)
# ---------------------------------------------------------------------------

class DemandeAuCoach(BaseModel):
    texte: str = Field(min_length=1)
    id_occurrence: int | None = None
    cle_client: UUID


class Pause(BaseModel):
    motif: str | None = None
    fin: date | None = None


@routeur.post("/coach/signalement", tags=["Coach"],
              summary="Signaler une douleur, une fatigue, un contretemps")
def signaler(qui: Authentifie, demande: DemandeAuCoach) -> dict:
    """COA-10 : un signalement déclenche un appel immédiat. Il n'attend jamais 23 h."""
    return demander_au_coach(qui.id_utilisateur, "signalement", demande.texte,
                             demande.id_occurrence, demande.cle_client)


@routeur.post("/coach/question", tags=["Coach"], summary="Poser une question")
def questionner(qui: Authentifie, demande: DemandeAuCoach) -> dict:
    """Si le texte est en fait un signalement, le coach le requalifie lui-même (COA-25)."""
    return demander_au_coach(qui.id_utilisateur, "chat", demande.texte,
                             demande.id_occurrence, demande.cle_client)


@routeur.get("/coach/echanges", tags=["Coach"], summary="Relire les échanges")
def relire_echanges(qui: Authentifie, limite: int = Query(default=20, ge=1, le=200),
                    moment: str | None = None) -> list[dict]:
    """CAR-8 : seul leur propriétaire les lit."""
    lignes = lister(
        """SELECT id_echange, quand, auteur, moment, contenu, elements, id_occurrence
             FROM echange
            WHERE id_utilisateur = %(u)s AND (%(m)s::TEXT IS NULL OR moment = %(m)s::TEXT)
            ORDER BY id_echange DESC LIMIT %(n)s""",
        {"u": qui.id_utilisateur, "m": moment, "n": limite})
    return [{**reponse.depuis_echange(ligne), "id_occurrence": ligne["id_occurrence"]}
            for ligne in lignes]


@routeur.post("/coach/synthese", tags=["Coach"], summary="Déclencher la synthèse du soir")
def declencher_synthese(qui: Administrateur, revision: bool = False,
                        pseudo: str | None = None) -> dict:
    """Réservé à l'administrateur. Sert à rejouer une soirée sans attendre 23 h."""
    cible = qui.id_utilisateur
    if pseudo:
        autre = un_seul("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %(p)s",
                        {"p": pseudo})
        if autre is None:
            raise _refuser("introuvable", "Compte inconnu", 404)
        cible = autre["id_utilisateur"]
    _exiger_coach(cible)
    cloture = planifie.clore_le_jour(cible)
    try:
        rendu = planifie.synthese(cible, "revision" if revision else "synthese", cloture)
    except appel.EchecAppel as echec:
        raise _refuser("coach_injoignable", f"Le coach n'a pas répondu : {echec.motif}",
                       503) from None
    return {"cloture": cloture, "coach": rendu}


@routeur.get("/coach/pause", tags=["Coach"], summary="La pause en cours, s'il y en a une")
def lire_pause(qui: Authentifie) -> dict:
    return {"pause": contexte.pause(qui.id_utilisateur)}


@routeur.post("/coach/pause", tags=["Coach"], status_code=201,
              summary="Mettre le coach en pause : motif, date de fin facultative")
def mettre_en_pause(qui: Authentifie, pause: Pause) -> dict:
    executer("SELECT mettre_en_pause(%(u)s, %(f)s, %(m)s)",
             {"u": qui.id_utilisateur, "f": pause.fin, "m": pause.motif})
    return {"pause": contexte.pause(qui.id_utilisateur)}


@routeur.delete("/coach/pause", tags=["Coach"], summary="Lever la pause")
def lever_pause(qui: Authentifie) -> dict:
    """PAU-6 : à la fin de la pause, le coach est appelé tout de suite. Il relit la
    période, détaille une semaine de reprise et la propose, par message."""
    en_cours = contexte.pause(qui.id_utilisateur)
    ligne = executer("SELECT lever_pause(%(u)s) AS levee", {"u": qui.id_utilisateur})
    if not ligne["levee"]:
        raise _refuser("introuvable", "Le coach n'est pas en pause", 404)
    motif = en_cours["motif"] if en_cours else None
    threading.Thread(target=planifie.reprise, args=(qui.id_utilisateur, motif),
                     name="coach-reprise", daemon=True).start()
    return {"levee": True, "message": "Pause levée. Le coach prépare la reprise et te "
                                      "l'envoie par message."}


@routeur.get("/coach/appels", tags=["Coach"],
             summary="Les appels au modèle et ce qu'ils ont consommé")
def lire_appels(qui: Administrateur, depuis: date | None = None) -> dict:
    """COA-21 : le suivi du coût, sans plafond."""
    debut = depuis or aujourd_hui() - timedelta(days=7)
    appels = lister(
        """SELECT a.id_appel, u.pseudo, a.moment, a.declencheur, a.statut, a.essai,
                  a.debut, a.fin, a.tours, a.tokens_entree, a.tokens_cache, a.tokens_sortie,
                  a.modele, a.motif_echec, a.operation, a.deroule
             FROM appel_coach a JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
            WHERE jour_de(a.debut) >= %(d)s ORDER BY a.id_appel DESC LIMIT 300""",
        {"d": debut})
    par_jour = lister(
        """SELECT jour, moment, modele, appels, echecs, tours, tokens_entree, tokens_cache,
                  tokens_sortie FROM v_cout_coach WHERE jour >= %(d)s
            ORDER BY jour DESC, moment""", {"d": debut})
    return {"depuis": debut, "par_jour": par_jour, "appels": appels}


@routeur.post("/coach/activer", tags=["Coach"], summary="Activer ou couper le coach")
def activer_coach(qui: Administrateur, pseudo: str | None = None, actif: bool = True) -> dict:
    """COA-1 : réservé à l'administrateur. Le coach s'active par compte, et le
    couper est un retour en arrière d'une ligne."""
    cible = un_seul("SELECT id_utilisateur, pseudo FROM utilisateur WHERE pseudo = %(p)s",
                    {"p": pseudo or qui.pseudo})
    if cible is None:
        raise _refuser("introuvable", "Compte inconnu", 404)
    executer("SELECT activer_coach(%(u)s, %(a)s)",
             {"u": cible["id_utilisateur"], "a": actif})
    return {"pseudo": cible["pseudo"], "coach_actif": actif,
            "manque": contexte.ce_qui_manque(cible["id_utilisateur"]) if actif else []}


# ---------------------------------------------------------------------------
# Suivi, catalogue, limitations                                          (EXO)
# ---------------------------------------------------------------------------

class Limitation(BaseModel):
    libelle: str = Field(max_length=100)
    zone: str = Field(max_length=30)
    cote: Literal["gauche", "droite", "deux"]
    description: str = Field(description="La fiche : ce que la base ne sait pas vérifier")


class LimitationModifiee(BaseModel):
    libelle: str | None = Field(default=None, max_length=100)
    zone: str | None = Field(default=None, max_length=30)
    cote: Literal["gauche", "droite", "deux"] | None = None
    description: str | None = None
    active: bool | None = None


class Interdit(BaseModel):
    code: str
    motif: str = Field(min_length=1)


@routeur.get("/progression", tags=["Coach : suivi"],
             summary="Les courbes d'un objectif ou d'un exercice")
def progression(qui: Authentifie, objectif: int | None = None,
                exercice: str | None = None) -> dict:
    rendu = outils.lire_progression(qui.id_utilisateur, {"exercice": exercice})
    if objectif is not None:
        vise = _objectif(qui.id_utilisateur, objectif)
        rendu["objectif"] = clair(vise)
        if vise["type_mesure"]:
            rendu["mesures"] = outils.lire_mesures(
                qui.id_utilisateur, {"type": vise["type_mesure"]})["mesures"]
    return rendu


@routeur.get("/exercices", tags=["Coach : suivi"], summary="Le catalogue")
def catalogue(qui: Authentifie, discipline: str | None = None,
              groupe: str | None = None) -> list[dict]:
    return lister(
        """SELECT e.id_exercice, e.code, e.libelle, e.discipline, e.groupe_principal,
                  e.groupes_secondaires, e.materiel, e.unilateral, e.mesure,
                  EXISTS (SELECT 1 FROM exercice_interdit ei
                            JOIN limitation l ON l.id_limitation = ei.id_limitation
                           WHERE l.id_utilisateur = %(u)s AND l.active
                             AND ei.id_exercice = e.id_exercice) AS interdit
             FROM exercice e
            WHERE e.actif
              AND (%(d)s::TEXT IS NULL OR e.discipline = %(d)s::TEXT)
              AND (%(g)s::TEXT IS NULL OR e.groupe_principal = %(g)s::TEXT)
            ORDER BY e.discipline, e.groupe_principal, e.libelle""",
        {"u": qui.id_utilisateur, "d": discipline, "g": groupe})


@routeur.get("/limitations", tags=["Coach : suivi"],
             summary="Mes limitations et les exercices qu'elles interdisent")
def lire_limitations(qui: Authentifie) -> list[dict]:
    return contexte.limitations(qui.id_utilisateur, actives=False)


@routeur.post("/limitations", tags=["Coach : suivi"], status_code=201,
              summary="Déclarer une limitation")
def declarer_limitation(qui: Authentifie, limitation: Limitation) -> dict:
    """EXO-9 : une limitation est la donnée d'un compte. Elle s'enregistre ici,
    jamais par une migration ni dans le dossier : le dépôt est public."""
    ligne = executer(
        """INSERT INTO limitation (id_utilisateur, libelle, zone, cote, description)
           VALUES (%(u)s, %(libelle)s, %(zone)s, %(cote)s, %(description)s)
           RETURNING id_limitation""",
        {"u": qui.id_utilisateur, **limitation.model_dump()})
    return {"id_limitation": ligne["id_limitation"]}


def _limitation_de(qui, id_limitation: int) -> None:
    if un_seul("SELECT 1 FROM limitation WHERE id_limitation = %(l)s "
               "AND id_utilisateur = %(u)s",
               {"l": id_limitation, "u": qui.id_utilisateur}) is None:
        raise _refuser("introuvable", "Limitation introuvable", 404)


@routeur.patch("/limitations/{id_limitation}", tags=["Coach : suivi"],
               summary="La modifier, la désactiver")
def modifier_limitation(qui: Authentifie, id_limitation: int,
                        champs: LimitationModifiee) -> list[dict]:
    _limitation_de(qui, id_limitation)
    voulus = champs.model_dump(exclude_unset=True)
    if voulus:
        affectations = ", ".join(f"{colonne} = %({colonne})s" for colonne in voulus)
        executer(f"UPDATE limitation SET {affectations} WHERE id_limitation = %(l)s",
                 {**voulus, "l": id_limitation})
    return contexte.limitations(qui.id_utilisateur, actives=False)


@routeur.put("/limitations/{id_limitation}/interdits", tags=["Coach : suivi"],
             summary="Remplacer la liste de ses exercices interdits")
def remplacer_interdits(qui: Authentifie, id_limitation: int,
                        interdits: list[Interdit]) -> dict:
    """EXO-8 : c'est l'utilisateur qui déclare ce qu'une limitation interdit."""
    _limitation_de(qui, id_limitation)
    codes = [i.code for i in interdits]
    connus = {ligne["code"]: ligne["id_exercice"] for ligne in lister(
        "SELECT code, id_exercice FROM exercice WHERE code = ANY (%(c)s::TEXT[])",
        {"c": codes})}
    inconnus = sorted(set(codes) - set(connus))
    if inconnus:
        raise _refuser("introuvable",
                       f"Exercices inconnus au catalogue : {', '.join(inconnus)}", 404)
    with connexion() as conn:
        conn.execute("DELETE FROM exercice_interdit WHERE id_limitation = %(l)s",
                     {"l": id_limitation})
        conn.execute(
            """INSERT INTO exercice_interdit (id_limitation, id_exercice, motif)
               SELECT %(l)s, (x ->> 'id')::INTEGER, x ->> 'motif'
                 FROM jsonb_array_elements(%(liste)s) x
               ON CONFLICT (id_limitation, id_exercice)
               DO UPDATE SET motif = EXCLUDED.motif""",
            {"l": id_limitation,
             "liste": Jsonb([{"id": connus[i.code], "motif": i.motif} for i in interdits])})
    return {"id_limitation": id_limitation, "interdits": len(interdits)}


# ---------------------------------------------------------------------------
# Lieux d'une discipline                                                 (LIE)
# ---------------------------------------------------------------------------

@routeur.get("/disciplines/lieux", tags=["Coach : suivi"],
             summary="Mes lieux par discipline, et ceux qu'on peut ajouter")
def lire_lieux(qui: Authentifie) -> dict:
    return {"choisis": contexte.lieux(qui.id_utilisateur),
            # LIE-4 : les lieux possibles sont ceux que le système connaît déjà.
            "possibles": lister("SELECT id_lieu, code, libelle FROM lieu_sport "
                                "ORDER BY libelle")}


@routeur.put("/disciplines/{discipline}/lieux", tags=["Coach : suivi"],
             summary="Choisir les lieux d'une discipline et leur ordre")
def choisir_lieux(qui: Authentifie, discipline: Discipline, lieux: list[int]) -> dict:
    uniques = list(dict.fromkeys(lieux))
    with connexion() as conn:
        conn.execute("DELETE FROM discipline_lieu "
                     "WHERE id_utilisateur = %(u)s AND discipline = %(d)s",
                     {"u": qui.id_utilisateur, "d": discipline})
        conn.execute(
            """INSERT INTO discipline_lieu (id_utilisateur, discipline, id_lieu, rang)
               SELECT %(u)s, %(d)s, l.id_lieu, l.rang::SMALLINT
                 FROM unnest(%(lieux)s::INTEGER[]) WITH ORDINALITY AS l(id_lieu, rang)""",
            {"u": qui.id_utilisateur, "d": discipline, "lieux": uniques})
    return {"choisis": contexte.lieux(qui.id_utilisateur)}


def heure_locale(jour: date, heure: time) -> datetime:
    """Une heure de Paris, pour les clients qui pensent en jour et en heure."""
    return datetime.combine(jour, heure, tzinfo=fuseau())
