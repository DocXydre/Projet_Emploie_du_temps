"""Ce que l'appli lit en ouvrant Aujourd'hui et Maison                  (lot 5)

Un seul appel rend tout ce que les widgets affichent : la journée, les tâches
des deux, le conflit en cours, les absences, le mode allégé, le chat,
l'équilibre et les week-ends proposés. L'appli le garde sur le téléphone : hors
réseau, elle montre le dernier reçu (APP-3).

Les widgets ne calculent rien (WID-8) : les catégories arrivent déjà dans le
vocabulaire de l'appli, et les dates en ISO 8601.

Le mode allégé a ses routes ici : jusque-là, seul le bot savait l'allumer.
"""

import json
from datetime import date
from uuid import UUID

from fastapi import APIRouter, HTTPException, status
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from api import allegement
from api.base import executer, lister, un_seul
from api.routeurs.coach import Bilan, Serie
from api.securite import Authentifie

routeur = APIRouter(tags=["Appli"])

# Le vocabulaire de l'appli : neuf couleurs, une par catégorie (C.4).
CATEGORIES = """
    CASE %s
        WHEN 'animal'    THEN 'chat'
        WHEN 'vaisselle' THEN 'menage'
        WHEN 'menage'    THEN 'menage'
        WHEN 'linge'     THEN 'linge'
        WHEN 'sport'     THEN 'sport'
        WHEN 'cours'     THEN 'cours'
        WHEN 'travail'   THEN 'travail'
        WHEN 'trajet'    THEN 'perso'
        WHEN 'weekend'   THEN 'perso'
        ELSE 'perso'
    END"""


def _categorie(colonne: str) -> str:
    return CATEGORIES % colonne


def _membres(moi: int) -> list[dict]:
    return lister(
        """
        SELECT u.id_utilisateur AS id, u.pseudo, u.nom,
               u.id_utilisateur = f.id_administrateur AS administrateur,
               u.id_utilisateur = %(moi)s AS moi
          FROM utilisateur u
          JOIN foyer f ON f.id_foyer = u.id_foyer
         WHERE u.id_foyer = foyer_de(%(moi)s) AND u.actif
         ORDER BY u.id_utilisateur <> %(moi)s, u.id_utilisateur
        """,
        {"moi": moi},
    )


@routeur.get("/appli/aujourdhui", summary="Tout ce qu'Aujourd'hui et Maison affichent")
def aujourdhui(qui: Authentifie) -> dict:
    moi = qui.id_utilisateur
    membres = _membres(moi) or [{"id": moi, "pseudo": qui.pseudo, "nom": qui.pseudo,
                                 "administrateur": False, "moi": True}]
    ids = [m["id"] for m in membres]
    params = {"moi": moi, "ids": ids}

    evenements = lister(
        f"""
        SELECT p.nature, p.id, p.libelle AS titre, p.debut, p.fin, p.journee_entiere,
               p.lieu, p.statut, {_categorie('p.categorie')} AS categorie
          FROM v_planning p
         WHERE p.id_utilisateur = %(moi)s
           AND p.categorie IS DISTINCT FROM 'sommeil'
           AND p.debut < debut_jour(jour_de(now()) + 1)
           AND p.fin   > debut_jour(jour_de(now()))
         ORDER BY p.journee_entiere DESC, p.debut, p.libelle
        """,
        params,
    )

    # Les tâches du jour des membres, faites comprises, et celles en retard.
    # Le sport a son onglet : il n'est pas ici.
    taches = lister(
        f"""
        SELECT o.id_occurrence AS id, o.id_tache, o.tache_code AS code,
               o.tache_libelle AS titre, o.id_utilisateur AS pour,
               {_categorie('o.categorie')} AS categorie, o.statut,
               o.statut = 'faite' AS faite, o.nb_relances AS reports,
               o.en_retard, o.debut, o.fin, o.rappel_journee AS journee_entiere,
               o.duree_minutes, o.actions_possibles
          FROM v_occurrence o
         WHERE o.categorie <> 'sport'
           AND o.id_utilisateur = ANY (%(ids)s)
           AND ((o.statut IN ('planifiee', 'notifiee')
                 AND o.debut < debut_jour(jour_de(now()) + 1))
                OR (o.statut = 'faite' AND jour_de(o.date_faite) = jour_de(now()))
                OR (o.en_retard AND o.statut NOT IN ('faite', 'abandonnee')))
         ORDER BY o.statut = 'faite', o.debut NULLS LAST, o.priorite
        """,
        params,
    )

    conflit = un_seul(
        """
        SELECT c.id_conflit AS id, jour_de(lower(c.periode)) AS jour,
               json_build_object('titre', oc.libelle, 'debut', lower(oc.periode),
                                 'fin', upper(oc.periode), 'lieu', oc.lieu) AS existante,
               json_build_object('titre', c.libelle, 'debut', lower(c.periode),
                                 'fin', upper(c.periode), 'lieu', c.lieu) AS nouvelle
          FROM conflit c
          JOIN source s ON s.id_source = c.id_source
          JOIN occupation oc ON oc.id_occupation = c.id_occupation
         WHERE c.statut = 'en_attente' AND s.id_utilisateur = %(moi)s
           AND upper(c.periode) > now()
         ORDER BY lower(c.periode)
         LIMIT 1
        """,
        params,
    )

    absences = lister(
        """
        SELECT id_absence AS id, id_utilisateur AS pour, lower(periode) AS debut,
               upper(periode) AS fin, lieu, origine
          FROM absence
         WHERE id_utilisateur = ANY (%(ids)s)
           AND upper(periode) > now() AND lower(periode) < now() + INTERVAL '30 days'
         ORDER BY lower(periode)
        """,
        params,
    )

    allegements = lister(
        """
        SELECT id_utilisateur AS pour, lower(periode) AS debut, upper(periode) AS fin
          FROM allegement
         WHERE id_utilisateur = ANY (%(ids)s) AND upper(periode) > now()
         ORDER BY lower(periode)
        """,
        params,
    )

    # Le chat : la prochaine fois pour chaque soin (4.1).
    chat = un_seul(
        """
        SELECT min(o.debut) FILTER (WHERE o.tache_code LIKE 'LITIERE%%') AS litiere,
               min(o.debut) FILTER (WHERE o.tache_code = 'EAU_SASSY') AS eau,
               min(o.debut) FILTER (WHERE o.tache_code = 'FONTAINE_SASSY') AS fontaine
          FROM v_occurrence o
         WHERE o.categorie = 'animal'
           AND o.statut IN ('planifiee', 'notifiee')
        """,
    )

    # L'équilibre : le temps passé aux tâches partagées sur sept jours.
    equilibre = lister(
        """
        SELECT u AS pour, COALESCE(sum(o.duree_minutes), 0)::INTEGER AS minutes
          FROM unnest(%(ids)s::INTEGER[]) AS u
          LEFT JOIN v_occurrence o
                 ON o.id_utilisateur = u AND o.statut = 'faite'
                AND o.categorie <> 'sport'
                AND o.date_faite > now() - INTERVAL '7 days'
         GROUP BY u
         ORDER BY u <> %(moi)s, u
        """,
        params,
    )

    propositions = lister(
        """
        SELECT id_proposition AS id, lower(periode) AS debut, upper(periode) AS fin, lieu
          FROM proposition
         WHERE statut = 'proposee' AND id_utilisateur = %(moi)s
         ORDER BY lower(periode)
        """,
        params,
    )

    orbe = un_seul(
        """
        SELECT EXISTS (SELECT 1 FROM notification n
                        WHERE n.id_utilisateur = u.id_utilisateur AND n.type = 'coach'
                          AND n.date_creation > COALESCE(u.orbe_vu_le, '-infinity'))
            OR EXISTS (SELECT 1 FROM ajustement a
                         JOIN occurrence o ON o.id_occurrence = a.id_occurrence
                        WHERE o.id_utilisateur = u.id_utilisateur
                          AND a.statut = 'propose') AS a_dire
          FROM utilisateur u WHERE u.id_utilisateur = %(moi)s
        """,
        params,
    )

    droits = un_seul(
        """SELECT droit_sur_les_taches(%(moi)s, 'ajouter') AS ajouter,
                  droit_sur_les_taches(%(moi)s, 'modifier') AS modifier""",
        params,
    )

    return {
        "jour": un_seul("SELECT jour_de(now()) AS jour")["jour"],
        "membres": membres,
        "evenements": evenements,
        "taches": taches,
        "conflit": conflit,
        "absences": absences,
        "allegements": allegements,
        "chat": chat,
        "equilibre": equilibre,
        "propositions": propositions,
        "orbe": bool(orbe and orbe["a_dire"]),
        "droits": droits,
    }


# -----------------------------------------------------------------------------
# Le mode allégé                                                       (PLA-16)
# -----------------------------------------------------------------------------
class DemandeAllegement(BaseModel):
    jours: int = Field(ge=1, le=14)


def _etat_allegement(moi: int, texte: str | None = None) -> dict:
    mien = allegement.en_cours(moi)
    return {"en_cours": mien is not None,
            "fin": mien["fin"] if mien else None,
            "texte": texte or allegement.ecran(moi).texte}


@routeur.get("/allegement", tags=["Appli"], summary="Mon mode allégé")
def lire_allegement(qui: Authentifie) -> dict:
    return _etat_allegement(qui.id_utilisateur)


@routeur.put("/allegement", tags=["Appli"], summary="Passer en mode allégé pour quelques jours")
def activer_allegement(demande: DemandeAllegement, qui: Authentifie) -> dict:
    ecran = allegement.activer(qui.id_utilisateur, demande.jours)
    return _etat_allegement(qui.id_utilisateur, ecran.texte)


@routeur.delete("/allegement", tags=["Appli"], summary="Arrêter le mode allégé")
def arreter_allegement(qui: Authentifie) -> dict:
    if allegement.en_cours(qui.id_utilisateur) is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "pas_allege", "message": "Tu n'es pas en mode allégé."})
    ecran = allegement.arreter(qui.id_utilisateur)
    return _etat_allegement(qui.id_utilisateur, ecran.texte)


# -----------------------------------------------------------------------------
# L'onglet Sport                                                       (lot 6)
# -----------------------------------------------------------------------------
@routeur.get("/appli/sport", summary="Tout ce que l'onglet Sport affiche")
def sport(qui: Authentifie) -> dict:
    """La semaine, les séances du jour avec leurs exercices et leurs alternatives
    (SAI-10 : de quoi faire la séance sans réseau), la forme des sept derniers
    jours, l'objectif principal, les mesures demandées, les ajustements en
    attente et la pause."""
    from api.coach import contexte, outils

    moi = qui.id_utilisateur
    params = {"moi": moi}
    semaine = un_seul(
        """
        SELECT count(*) FILTER (WHERE situation = 'faite')::INTEGER AS faites,
               count(*) FILTER (WHERE situation NOT IN ('retiree', 'remplacee', 'esquisse')
                                )::INTEGER AS prevues
          FROM v_seance_coach
         WHERE id_utilisateur = %(moi)s AND lundi = date_trunc('week', jour_de(now()))::DATE
        """,
        params,
    )
    prochaine = un_seul(
        """
        SELECT id_occurrence, debut, discipline, type_seance, duree_minutes, situation
          FROM v_seance_coach
         WHERE id_utilisateur = %(moi)s AND debut > now()
           AND situation NOT IN ('faite', 'pas_faite', 'retiree', 'remplacee')
         ORDER BY debut LIMIT 1
        """,
        params,
    )
    du_jour = [outils.detail_seance(moi, ligne["id_occurrence"]) for ligne in lister(
        """SELECT id_occurrence FROM v_seance_coach
            WHERE id_utilisateur = %(moi)s AND jour = jour_de(now()) AND discipline IS NOT NULL
            ORDER BY debut NULLS LAST""", params)]
    forme = lister(
        """
        SELECT jour, pas, fc_repos, vfc_ms::FLOAT AS vfc_ms, sommeil_minutes
          FROM sante_jour
         WHERE id_utilisateur = %(moi)s AND jour > jour_de(now()) - 7
         ORDER BY jour DESC
        """,
        params,
    )
    objectif = un_seul(
        """
        SELECT id_objectif, libelle, echeance, date_creation,
               (echeance - jour_de(now()))::INTEGER AS jours_restants
          FROM objectif
         WHERE id_utilisateur = %(moi)s AND statut = 'actif'
         ORDER BY principal DESC, rang, id_objectif LIMIT 1
        """,
        params,
    )
    # MES-1 : une fenêtre ne se montre qu'une fois commencée. Rattachée à une
    # séance de test (MES-6), elle attend le jour de cette séance.
    mesures = lister(
        """SELECT f.id_fenetre, f.type_mesure, lower(f.periode) AS du,
                  upper(f.periode) - 1 AS au, f.consigne, s.jour AS jour_seance
             FROM fenetre_mesure f
             LEFT JOIN v_seance_coach s ON s.id_occurrence = f.id_occurrence
            WHERE f.id_utilisateur = %(moi)s AND f.statut = 'ouverte'
              AND lower(f.periode) <= jour_de(now())
              AND (s.jour IS NULL OR s.jour <= jour_de(now()))
            ORDER BY lower(f.periode)""",
        params,
    )
    ajustements = lister(
        """SELECT a.id_ajustement, a.id_occurrence, a.nature, a.motif,
                  s.jour, s.type_seance, s.discipline
             FROM ajustement a JOIN v_seance_coach s ON s.id_occurrence = a.id_occurrence
            WHERE s.id_utilisateur = %(moi)s AND a.statut = 'propose'
            ORDER BY s.debut""",
        params,
    )
    # PLN-6 : la semaine que HAL attend de voir validée, celle-ci ou la suivante.
    a_valider = un_seul(
        """SELECT lundi, count(*)::INTEGER AS seances
             FROM v_seance_coach
            WHERE id_utilisateur = %(moi)s AND situation = 'proposee'
              AND lundi >= date_trunc('week', jour_de(now()))::DATE
            GROUP BY lundi ORDER BY lundi LIMIT 1""",
        params,
    )
    compte = un_seul("SELECT coach_actif FROM utilisateur WHERE id_utilisateur = %(moi)s",
                     params)
    return {
        "coach_actif": bool(compte and compte["coach_actif"]),
        "semaine": {**(semaine or {"faites": 0, "prevues": 0}), "prochaine": prochaine},
        "seances_du_jour": [d for d in du_jour if d is not None],
        "forme": forme,
        "objectif": objectif,
        "mesures": mesures,
        "ajustements": ajustements,
        "pause": contexte.pause(moi),
        "semaine_a_valider": a_valider,
        "invitations": _invitations(moi),
        # DEM-1 : le premier bloc du démarrage qui manque, ou rien s'il est fini.
        "demarrage": _bloc_du_demarrage(moi),
    }


def _bloc_du_demarrage(moi: int) -> str | None:
    from api.coach import demarrage

    return demarrage.bloc_manquant(moi)


def _invitations(moi: int) -> list[dict]:
    """SPT-31 : les séances où l'autre propose de venir, en attente de réponse."""
    return lister(
        """SELECT inv.id_invitation, u.nom AS qui, l.libelle AS lieu, o.debut_seance AS debut
             FROM invitation_sport inv
             JOIN occurrence o ON o.id_occurrence = inv.id_occurrence
             JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
             LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
            WHERE inv.id_invite = %(moi)s AND inv.statut = 'attente'
              AND o.debut_seance > now()
            ORDER BY o.debut_seance""",
        {"moi": moi},
    )


class Reponse(BaseModel):
    vient: bool


@routeur.post("/seances/invitations/{id_invitation}/repondre", tags=["Coach : séances"],
              summary="« Je viens » ou « pas cette fois » à une séance à deux")
def repondre_invitation(id_invitation: int, reponse: Reponse, qui: Authentifie) -> dict:
    """SPT-32 : venir pose la même séance, au même lieu et à la même heure."""
    ligne = un_seul("SELECT repondre_invitation(%(i)s, %(u)s, %(v)s) AS id_occurrence",
                    {"i": id_invitation, "u": qui.id_utilisateur, "v": reponse.vient})
    return {"id_occurrence": (ligne or {}).get("id_occurrence"), "vient": reponse.vient}


@routeur.get("/appli/semaine", summary="Les séances d'une semaine, pour la valider")
def semaine_de_sport(qui: Authentifie, lundi: date | None = None) -> dict:
    """3.2 : une validation pour toute la semaine (PLN-6)."""
    params = {"moi": qui.id_utilisateur, "lundi": lundi}
    debut = un_seul(
        "SELECT date_trunc('week', COALESCE(%(lundi)s::DATE, jour_de(now())))::DATE AS lundi",
        params)["lundi"]
    params["lundi"] = debut
    seances = lister(
        """SELECT id_occurrence, jour, debut, discipline, type_seance, intensite,
                  duree_minutes, situation, lieu, consigne, exercices
             FROM v_seance_coach
            WHERE id_utilisateur = %(moi)s AND lundi = %(lundi)s
            ORDER BY jour, debut NULLS LAST, id_occurrence""",
        params,
    )
    plan = un_seul(
        """SELECT ps.role, ps.intention, ps.validee_le
             FROM plan p JOIN plan_semaine ps ON ps.id_plan = p.id_plan
            WHERE p.id_utilisateur = %(moi)s AND p.statut = 'en_cours' AND ps.lundi = %(lundi)s""",
        params,
    )
    # Chapitre 8.1 : la charge d'entraînement, vide tant qu'aucun bilan n'existe.
    charge = un_seul(
        """SELECT charge_7j::FLOAT AS charge_sept_jours,
                  charge_28j::FLOAT AS charge_quatre_semaines, rapport::FLOAT AS rapport,
                  seances_7j AS seances_sept_jours, seances_sans_bilan_28j AS seances_sans_bilan
             FROM v_charge_entrainement WHERE id_utilisateur = %(moi)s""",
        params,
    )
    return {"lundi": debut, "role": (plan or {}).get("role"), "charge": charge,
            "intention": (plan or {}).get("intention"),
            "validee_le": (plan or {}).get("validee_le"),
            "a_valider": any(s["situation"] == "proposee" for s in seances),
            "seances": seances}


@routeur.get("/appli/sante", summary="Sommeil et récupération sur 7, 30 ou 90 jours")
def sante(qui: Authentifie, jours: int = 30) -> dict:
    """3.16 : un jour sans donnée reste vide, jamais un zéro (SAN-5)."""
    params = {"moi": qui.id_utilisateur, "jours": max(1, min(jours, 365))}
    return {
        "jours": lister(
            """SELECT jour, pas, fc_repos, vfc_ms::FLOAT AS vfc_ms, sommeil_minutes
                 FROM sante_jour
                WHERE id_utilisateur = %(moi)s AND jour > jour_de(now()) - %(jours)s
                ORDER BY jour""", params),
        "seances": lister(
            """SELECT a.type, a.discipline, lower(a.periode) AS debut, a.duree_secondes,
                      a.distance_m, a.fc_moyenne, a.fc_max, a.allure_s_km, a.energie_kcal
                 FROM activite_sante a
                WHERE a.id_utilisateur = %(moi)s
                  AND lower(a.periode) > now() - make_interval(days => %(jours)s)
                ORDER BY lower(a.periode) DESC""", params),
    }


@routeur.get("/appli/mesures", summary="L'historique des mesures, poids, tours et tests")
def historique_des_mesures(qui: Authentifie, type: str | None = None) -> list[dict]:
    """3.1 et 3.19 : les mesures, des plus récentes aux plus anciennes (MES-4)."""
    return lister(
        """SELECT id_mesure, type_mesure, valeur::FLOAT AS valeur, unite, cote, date_mesure
             FROM mesure
            WHERE id_utilisateur = %(moi)s
              AND (%(t)s::TEXT IS NULL OR type_mesure = %(t)s::TEXT)
            ORDER BY date_mesure DESC, id_mesure DESC LIMIT 200""",
        {"moi": qui.id_utilisateur, "t": type},
    )


@routeur.get("/appli/progression", summary="La progression des exercices, semaine par semaine")
def progression(qui: Authentifie, exercice: str | None = None) -> list[dict]:
    """3.17 : la meilleure charge et le volume de chaque semaine, sur douze semaines."""
    return lister(
        """SELECT code, libelle, lundi, meilleure_charge::FLOAT AS meilleure_charge,
                  meilleures_repetitions, volume::FLOAT AS volume, series
             FROM v_progression
            WHERE id_utilisateur = %(moi)s
              AND (%(c)s::TEXT IS NULL OR code = %(c)s::TEXT)
              AND lundi > jour_de(now()) - 84
            ORDER BY libelle, lundi""",
        {"moi": qui.id_utilisateur, "c": exercice},
    )


# -----------------------------------------------------------------------------
# Une séance libre ouverte hors réseau                          (SAI-9, SAI-10)
#
# Sans réseau, l'appli ne connaît pas encore le numéro de la séance libre
# qu'elle vient d'ouvrir : elle ne connaît que la clé qu'elle lui a donnée. Ses
# séries et son bilan la désignent par cette clé. La file d'attente envoie dans
# l'ordre : la séance arrive toujours avant ses séries.
# -----------------------------------------------------------------------------
def _par_cle(moi: int, cle: UUID) -> int:
    ligne = un_seul(
        """SELECT s.id_occurrence FROM seance s
             JOIN occurrence o ON o.id_occurrence = s.id_occurrence
            WHERE s.cle_client = %(c)s AND o.id_utilisateur = %(moi)s""",
        {"c": cle, "moi": moi})
    if ligne is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": "Séance inconnue pour cette clé"})
    return ligne["id_occurrence"]


@routeur.post("/seances/par-cle/{cle}/series", tags=["Coach : séances"],
              summary="Les séries d'une séance désignée par la clé de l'appareil")
def series_par_cle(cle: UUID, series: list[Serie] | Serie, qui: Authentifie) -> dict:
    from api.routeurs.coach import enregistrer_series
    return enregistrer_series(qui, _par_cle(qui.id_utilisateur, cle), series)


@routeur.post("/seances/par-cle/{cle}/bilan", tags=["Coach : séances"],
              summary="Le bilan d'une séance désignée par la clé de l'appareil")
def bilan_par_cle(cle: UUID, bilan: Bilan, qui: Authentifie,
                  appeler_coach: bool = False) -> dict:
    from api.routeurs.coach import enregistrer_bilan
    return enregistrer_bilan(qui, _par_cle(qui.id_utilisateur, cle), bilan, appeler_coach)


# -----------------------------------------------------------------------------
# Le démarrage de HAL dans l'appli                               (DEM-1 à DEM-6)
#
# L'appli pose les questions écran par écran. Les réponses en cours sont
# gardées en base, sous la clé « _appli » de `demarrage_coach`, à côté de ce que
# le bot y garde : on peut commencer d'un côté et finir de l'autre sans que
# l'un efface l'autre. Chaque bloc fini passe par sa route habituelle (profil,
# limitations, lieux, objectif) : rien ne contourne une règle (DEM-2).
# -----------------------------------------------------------------------------
class Brouillon(BaseModel):
    etape: str = Field(max_length=30)
    reponses: dict = Field(default_factory=dict)


class MaximumDeSeances(BaseModel):
    valeur: int | None = Field(default=None, ge=1, le=14)


def _reponses_du_demarrage(moi: int) -> dict:
    ligne = un_seul("SELECT reponses FROM demarrage_coach WHERE id_utilisateur = %(u)s",
                    {"u": moi})
    return (ligne or {}).get("reponses") or {}


def _garder_le_demarrage(moi: int, etape: str, reponses: dict) -> None:
    executer(
        """INSERT INTO demarrage_coach (id_utilisateur, etape, reponses)
           VALUES (%(u)s, %(e)s, %(r)s)
           ON CONFLICT (id_utilisateur) DO UPDATE
              SET etape = EXCLUDED.etape, reponses = EXCLUDED.reponses, maj = now()""",
        {"u": moi, "e": etape[:30], "r": Jsonb(reponses)})


@routeur.get("/appli/demarrage", summary="Où en est le démarrage de HAL")
def demarrage_de_hal(qui: Authentifie) -> dict:
    """DEM-1, DEM-4 : ce qui manque, ce qui est déjà rempli, et le brouillon en cours."""
    from api.coach import contexte, demarrage

    moi = qui.id_utilisateur
    reponses = _reponses_du_demarrage(moi)
    reglages = contexte.reglages(moi)
    brouillon = reponses.get("_appli") or {}
    return {
        "manque": demarrage.bloc_manquant(moi),
        "coach_actif": bool(reglages.get("coach_actif")),
        "seances_max_semaine": reglages.get("seances_max_semaine"),
        "etape": brouillon.get("etape"),
        "brouillon": brouillon.get("reponses") or {},
        "limitations_faites": bool(reponses.get("_limitations_faites")),
        "profil": contexte.profil(moi),
        "limitations": contexte.limitations(moi, actives=False),
        "lieux": contexte.lieux(moi),
        "lieux_possibles": lister(
            "SELECT id_lieu, code, libelle FROM lieu_sport ORDER BY libelle"),
        "objectifs": contexte.objectifs(moi),
        "plan": contexte.plan(moi) is not None,
        "pause": contexte.pause(moi),
    }


@routeur.put("/appli/demarrage/brouillon", summary="Garder les réponses en cours")
def garder_le_brouillon(qui: Authentifie, brouillon: Brouillon) -> dict:
    """DEM-2 : les réponses en cours ne deviennent rien tant que leur bloc n'est pas fini."""
    if len(json.dumps(brouillon.reponses)) > 16_000:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                            detail={"code": "requete_invalide",
                                    "message": "Le brouillon est trop long"})
    reponses = _reponses_du_demarrage(qui.id_utilisateur)
    reponses["_appli"] = {"etape": brouillon.etape, "reponses": brouillon.reponses}
    _garder_le_demarrage(qui.id_utilisateur, brouillon.etape, reponses)
    return {"etape": brouillon.etape}


@routeur.post("/appli/demarrage/limitations-faites",
              summary="La question des limitations a eu sa réponse")
def limitations_faites(qui: Authentifie) -> dict:
    """DEM-3 : la question est posée une fois, et n'est pas reposée."""
    reponses = _reponses_du_demarrage(qui.id_utilisateur)
    reponses["_limitations_faites"] = True
    _garder_le_demarrage(qui.id_utilisateur, "limitations", reponses)
    return {"limitations_faites": True}


@routeur.post("/appli/demarrage/activer", summary="Activer HAL pour soi")
def activer_hal(qui: Authentifie) -> dict:
    """COA-1 : HAL s'active pour chaque membre. La base exige un profil, et refuse
    une personne mineure (PRO-7)."""
    from api.coach import contexte

    executer("SELECT activer_coach(%(u)s, TRUE)", {"u": qui.id_utilisateur})
    return {"coach_actif": True, "manque": contexte.ce_qui_manque(qui.id_utilisateur)}


@routeur.put("/appli/seances-max", summary="Le maximum de séances par semaine")
def regler_le_maximum(qui: Authentifie, maximum: MaximumDeSeances) -> dict:
    """5.5, PLN-14 : vide, HAL décide seul du nombre de séances."""
    executer("UPDATE utilisateur SET seances_max_semaine = %(v)s WHERE id_utilisateur = %(u)s",
             {"v": maximum.valeur, "u": qui.id_utilisateur})
    return {"seances_max_semaine": maximum.valeur}
