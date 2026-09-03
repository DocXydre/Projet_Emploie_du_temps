"""Occurrences : consulter, créer, valider, reporter, refuser.

Aucune règle métier ici. Valider une tâche, c'est appeler `valider_occurrence`
et laisser les triggers créer la suivante, déclencher les enchaînements et
mettre à jour le stock.
"""

from datetime import datetime

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, Field

from api.base import executer, lister, un_seul
from api.securite import Authentifie

routeur = APIRouter(prefix="/occurrences", tags=["Tâches"])

COLONNES = """
    id_occurrence, id_tache, tache_code, tache_libelle, categorie, priorite,
    duree_minutes, id_utilisateur, assigne_a, echeance_min, echeance_max,
    debut, fin, statut, origine, epinglee, rappel_journee, utilise_machine,
    nb_relances, motif, date_faite, en_retard, jours_de_retard, actions_possibles
"""


class DemandeCreation(BaseModel):
    id_tache: int
    id_utilisateur: int | None = None
    echeance_min: datetime
    echeance_max: datetime
    motif: str | None = None


class DemandeValidation(BaseModel):
    date_reelle: datetime | None = Field(
        default=None,
        description="Date réelle d'exécution. C'est elle qui sert de point de "
        "départ à la prochaine occurrence, pas l'échéance théorique.",
    )


class DemandeSpontanee(BaseModel):
    code_tache: str = Field(description="Code de la tâche, par exemple ASPIRATEUR")
    quand: datetime | None = Field(
        default=None, description="Quand elle a été faite. Maintenant par défaut."
    )


class DemandeReport(BaseModel):
    nouvelle_echeance: datetime | None = None
    motif: str | None = None


@routeur.get("", summary="Lister les occurrences")
def lister_occurrences(
    qui: Authentifie,
    statut_filtre: list[str] | None = Query(default=None, alias="statut"),
    assigne: int | None = None,
) -> list[dict]:
    return lister(
        f"""
        SELECT {COLONNES} FROM v_occurrence
         -- Les casts sont obligatoires : PostgreSQL refuse un paramètre nul
         -- dont il ne peut pas déduire le type.
         WHERE (%(statuts)s::TEXT[] IS NULL OR statut = ANY(%(statuts)s::TEXT[]))
           AND (%(assigne)s::INT IS NULL OR id_utilisateur = %(assigne)s::INT)
         ORDER BY priorite, echeance_max
        """,
        {"statuts": statut_filtre, "assigne": assigne},
    )


@routeur.get("/en-retard", summary="Occurrences en retard")
def occurrences_en_retard(qui: Authentifie) -> list[dict]:
    return lister(f"SELECT {COLONNES} FROM v_taches_en_retard")


@routeur.get("/{id_occurrence}", summary="Détail d'une occurrence")
def detail(id_occurrence: int, qui: Authentifie) -> dict:
    ligne = un_seul(
        f"SELECT {COLONNES} FROM v_occurrence WHERE id_occurrence = %(id)s",
        {"id": id_occurrence},
    )
    if ligne is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": f"Occurrence {id_occurrence} inconnue"},
        )
    return ligne


@routeur.post("", status_code=status.HTTP_201_CREATED, summary="Créer une occurrence à la main")
def creer(demande: DemandeCreation, qui: Authentifie) -> dict:
    cree = executer(
        """
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine, motif, epinglee)
        VALUES (%(tache)s,
                COALESCE(%(utilisateur)s, %(appelant)s),
                fenetre_pour((SELECT rappel_journee FROM tache WHERE id_tache = %(tache)s),
                             %(min)s, %(max)s),
                'manuelle', %(motif)s, TRUE)
        RETURNING id_occurrence
        """,
        {
            "tache": demande.id_tache,
            "utilisateur": demande.id_utilisateur,
            "appelant": qui.id_utilisateur,
            "min": demande.echeance_min,
            "max": demande.echeance_max,
            "motif": demande.motif or "Création manuelle",
        },
    )
    assert cree is not None
    return detail(cree["id_occurrence"], qui)


@routeur.post("/faite", summary="Déclarer une tâche faite, prévue ou non")
def faite(demande: DemandeSpontanee, qui: Authentifie) -> dict:
    """« J'ai passé l'aspirateur », sans qu'il ait été demandé aujourd'hui.

    Reprend l'occurrence ouverte s'il y en a une, en crée une sinon. Dans les
    deux cas la récurrence repart de la date déclarée : le prochain passage se
    compte à partir de maintenant, pas de l'échéance qui était prévue.
    """
    resultat = un_seul(
        "SELECT declarer_faite(%(u)s, %(c)s, %(q)s) AS id_occurrence",
        {"u": qui.id_utilisateur, "c": demande.code_tache.upper(), "q": demande.quand},
    )
    assert resultat is not None
    return detail(resultat["id_occurrence"], qui)


@routeur.post("/{id_occurrence}/valider", summary="Valider, éventuellement rétroactivement")
def valider(id_occurrence: int, qui: Authentifie, demande: DemandeValidation | None = None) -> dict:
    executer(
        "SELECT valider_occurrence(%(id)s, %(acteur)s, %(date)s)",
        {
            "id": id_occurrence,
            "acteur": qui.id_utilisateur,
            "date": demande.date_reelle if demande else None,
        },
    )
    return detail(id_occurrence, qui)


@routeur.post("/{id_occurrence}/reporter", summary="Reporter une occurrence")
def reporter(id_occurrence: int, qui: Authentifie, demande: DemandeReport | None = None) -> dict:
    nouvelle = demande.nouvelle_echeance if demande else None

    executer(
        """
        UPDATE occurrence o
           SET statut  = 'a_placer',
               creneau = NULL,
               fenetre = fenetre_pour(o.rappel_journee, now(),
                                      COALESCE(%(nouvelle)s, upper(o.fenetre) + INTERVAL '1 day')),
               motif   = COALESCE(%(motif)s, 'Reportée à la demande')
          FROM tache t
         WHERE t.id_tache = o.id_tache
           AND o.id_occurrence = %(id)s
           AND t.reportable
        """,
        {"id": id_occurrence, "nouvelle": nouvelle, "motif": demande.motif if demande else None},
    )

    ligne = detail(id_occurrence, qui)
    if ligne["statut"] != "a_placer":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "code": "non_reportable",
                "message": "Cette tâche ne peut pas être repoussée : la repousser "
                "ne résoudrait rien.",
            },
        )
    return ligne


@routeur.post("/{id_occurrence}/refuser", summary="Refuser une occurrence")
def refuser(id_occurrence: int, qui: Authentifie, demande: DemandeReport | None = None) -> dict:
    # L'occurrence est soldée, une remplaçante non assignée prend le relais :
    # rien ne disparaît, et l'autre personne peut la reprendre.
    nouvelle = executer(
        """
        WITH refusee AS (
            UPDATE occurrence
               SET statut = 'abandonnee',
                   motif  = COALESCE(%(motif)s, 'Refusée')
             WHERE id_occurrence = %(id)s
            RETURNING id_tache, fenetre, id_occurrence
        )
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine,
                                id_occurrence_source, motif)
        SELECT r.id_tache, NULL, r.fenetre, 'manuelle', r.id_occurrence,
               'À réassigner après refus'
          FROM refusee r
        RETURNING id_occurrence
        """,
        {"id": id_occurrence, "motif": demande.motif if demande else None},
    )
    assert nouvelle is not None
    return detail(nouvelle["id_occurrence"], qui)
