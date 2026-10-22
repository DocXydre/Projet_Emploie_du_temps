"""Définitions de tâches : récurrentes, ponctuelles ou nées d'une autre.

Depuis la migration 067, l'appli crée une tâche datée ou à une heure, la range
dans un type du foyer, et la relie à d'autres (TAC-20 à TAC-28). Chaque geste
appelle une fonction de la base, qui refuse avec son motif ce qui ne tient pas.
"""

from datetime import date, time
from typing import Literal

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api.base import connexion, executer, lister, un_seul
from api.securite import Appelant, Authentifie

routeur = APIRouter(prefix="/taches", tags=["Tâches"])

# Ce que l'appli lit d'une tâche : la ligne, son type, et de quoi dire son rythme
# et son heure sans rien recalculer (WID-8).
LIRE_TACHES = """
    SELECT t.*,
           CASE WHEN y.id_type_tache IS NULL THEN NULL
                ELSE json_build_object('id', y.id_type_tache, 'libelle', y.libelle,
                                       'couleur', y.couleur, 'icone', y.icone)
           END AS type,
           (SELECT json_agg(json_build_object(
                       'id_tache_suivante', e.id_tache_suivante,
                       'code', c.code,
                       'delai_min_heures', e.delai_min_heures,
                       'delai_max_heures', e.delai_max_heures))
              FROM enchainement e
              JOIN tache c ON c.id_tache = e.id_tache_suivante
             WHERE e.id_tache_source = t.id_tache) AS declenche,
           (SELECT json_build_object('debut', lower(o.fenetre), 'fin', upper(o.fenetre))
              FROM occurrence o
             WHERE o.id_tache = t.id_tache AND NOT t.recurrente
               AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
             ORDER BY lower(o.fenetre) LIMIT 1) AS dates,
           EXISTS (SELECT 1 FROM enchainement e
                    WHERE e.id_tache_suivante = t.id_tache) AS nait_d_une_autre,
           -- CND-16 : le détail montre ses règles ; la liste, qu'il y en a.
           (SELECT count(*) FROM regle_tache r
             WHERE r.id_tache = t.id_tache AND r.etat = 'active')::INTEGER AS regles,
           COALESCE(t.penibilite, y.penibilite) AS penibilite_effective
      FROM tache t
      LEFT JOIN type_tache y ON y.id_type_tache = t.id_type_tache
"""


class DemandeTache(BaseModel):
    code: str = Field(pattern=r"^[A-Z0-9_]{3,30}$")
    libelle: str
    categorie: str
    priorite: int = Field(default=3, ge=1, le=5)
    duree_minutes: int = Field(gt=0)
    periodicite_min_jours: int = Field(gt=0)
    periodicite_max_jours: int = Field(gt=0)
    rappel_journee: bool = True
    heure_min: time | None = None
    heure_max: time | None = None
    utilise_machine: bool = False
    requiert_les_deux: bool = False
    reportable: bool = True
    id_utilisateur_defaut: int | None = None
    # TAC-25 : sans type, le premier type de sa famille. Un sport n'en a pas.
    id_type_tache: int | None = None


class ModificationTache(BaseModel):
    libelle: str | None = None
    priorite: int | None = Field(default=None, ge=1, le=5)
    duree_minutes: int | None = Field(default=None, gt=0)
    periodicite_min_jours: int | None = Field(default=None, gt=0)
    periodicite_max_jours: int | None = Field(default=None, gt=0)
    id_utilisateur_defaut: int | None = None
    active: bool | None = None
    # TAC-25 : le type, dont la famille technique suit.
    id_type_tache: int | None = None
    # CND-4 : N fois par semaine ou par mois, au lieu de tous les N jours.
    rythme_nombre: int | None = Field(default=None, ge=1, le=31)
    rythme_periode: Literal["semaine", "mois"] | None = None
    rythme_moment: Literal["debut", "milieu", "fin", "indifferent"] | None = None
    # REP-3 : de 1 à 3 ; la tâche suit son type tant qu'on ne la change pas.
    penibilite: int | None = Field(default=None, ge=1, le=3)
    # TAC-23 : « sans_heure » rend la tâche à la journée ; sinon les deux bornes.
    sans_heure: bool = False
    heure_min: time | None = None
    heure_max: time | None = None


class NouvelleTache(BaseModel):
    """TAC-20 à TAC-24 : une seule façon de revenir, et l'une de trois heures.

    Régulière : `tous_les_jours`, ou `fois` par `par` (CND-4). Une fois : `au`,
    et `du` s'il n'est pas aujourd'hui. Après une autre : `apres`, et le délai
    en heures.
    """

    libelle: str
    id_type_tache: int | None = None
    duree_minutes: int | None = Field(default=None, ge=1, le=480)
    pour: int | None = None
    tous_les_jours: int | None = Field(default=None, ge=1, le=730)
    fois: int | None = Field(default=None, ge=1, le=31)
    par: Literal["semaine", "mois"] | None = None
    moment: Literal["debut", "milieu", "fin", "indifferent"] = "indifferent"
    du: date | None = None
    au: date | None = None
    apres: int | None = None
    delai_min_heures: int | None = Field(default=None, ge=0)
    delai_max_heures: int | None = Field(default=None, gt=0)
    heure_min: time | None = None
    heure_max: time | None = None
    si_pas_faite: Literal["reporter", "oublier"] = "reporter"


class NouveauLien(BaseModel):
    """TAC-27 : « ensuite » prend un délai, « meme_jour » une place."""

    sorte: Literal["ensuite", "meme_jour", "vaut_aussi"]
    id_autre: int
    delai_min_heures: int = Field(default=0, ge=0)
    delai_max_heures: int = Field(default=24, gt=0)
    place: Literal["avant", "apres"] = "avant"
    mention: str | None = Field(default=None, max_length=60)


def _exiger_droit(qui: Appelant, geste: str) -> None:
    """FOY-6 : l'administrateur du foyer décide qui ajoute, modifie et arrête."""
    ligne = un_seul("SELECT droit_sur_les_taches(%(u)s, %(g)s) AS permis",
                    {"u": qui.id_utilisateur, "g": geste})
    if not (ligne and ligne["permis"]):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"code": "droits_insuffisants",
                    "message": "L'administrateur du foyer garde les tâches pour lui"},
        )


def _une_tache(id_tache: int) -> dict:
    tache = un_seul(LIRE_TACHES + " WHERE t.id_tache = %(id)s", {"id": id_tache})
    if tache is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": f"Tâche {id_tache} inconnue"},
        )
    return tache


def _replacer() -> None:
    """Lot 5 : l'appli demande le replacement dans la même requête. Le
    déclencher à part est réservé au réseau privé (CNX-5)."""
    from api import ordonnanceur
    ordonnanceur.placer()


@routeur.get("", summary="Lister les tâches")
def lister_taches(qui: Authentifie, seulement_actives: bool = True) -> list[dict]:
    return lister(
        LIRE_TACHES + """
         WHERE (NOT %(actives)s::BOOLEAN OR t.active)
         ORDER BY y.ordre NULLS LAST, t.priorite, t.libelle
        """,
        {"actives": seulement_actives},
    )


@routeur.post("/nouvelle", status_code=status.HTTP_201_CREATED,
              summary="Créer une tâche : rythme, dates ou après une autre, heure")
def creer_depuis_l_appli(demande: NouvelleTache, qui: Authentifie) -> dict:
    """TAC-20 à TAC-24. La base vérifie tout et refuse avec son motif."""
    _exiger_droit(qui, "ajouter")
    cree = executer(
        """
        SELECT creer_tache(
            p_libelle => %(libelle)s, p_acteur => %(moi)s, p_type => %(type)s,
            p_duree_minutes => %(duree)s, p_pour => %(pour)s,
            p_tous_les_jours => %(rythme)s, p_du => %(du)s, p_au => %(au)s,
            p_apres => %(apres)s, p_delai_min_heures => %(dmin)s,
            p_delai_max_heures => %(dmax)s, p_heure_min => %(hmin)s,
            p_heure_max => %(hmax)s, p_si_pas_faite => %(oubli)s,
            p_fois => %(fois)s, p_par => %(par)s, p_moment => %(moment)s) AS id_tache
        """,
        {
            "libelle": demande.libelle,
            "moi": qui.id_utilisateur,
            "type": demande.id_type_tache,
            "duree": demande.duree_minutes,
            "pour": demande.pour,
            "rythme": demande.tous_les_jours,
            "du": demande.du,
            "au": demande.au,
            "apres": demande.apres,
            "dmin": demande.delai_min_heures,
            "dmax": demande.delai_max_heures,
            "hmin": demande.heure_min,
            "hmax": demande.heure_max,
            "oubli": demande.si_pas_faite,
            "fois": demande.fois,
            "par": demande.par,
            "moment": demande.moment,
        },
    )
    assert cree is not None
    _replacer()
    return _une_tache(cree["id_tache"])


@routeur.post("", status_code=status.HTTP_201_CREATED, summary="Créer une tâche")
def creer(demande: DemandeTache, qui: Authentifie, replacer: bool = False) -> dict:
    _exiger_droit(qui, "ajouter")
    cree = executer(
        """
        INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                           periodicite_min_jours, periodicite_max_jours,
                           rappel_journee, heure_min, heure_max, utilise_machine,
                           requiert_les_deux, reportable, id_utilisateur_defaut,
                           ajoutee_par, id_type_tache)
        VALUES (%(code)s, %(libelle)s, %(categorie)s::VARCHAR, %(priorite)s, %(duree)s,
                %(min)s, %(max)s, %(rappel)s, %(hmin)s, %(hmax)s, %(machine)s,
                %(duo)s, %(reportable)s, %(defaut)s, %(moi)s,
                -- Le même paramètre sert de colonne et de comparaison : sans
                -- type écrit, PostgreSQL en déduit deux et refuse (42P08).
                CASE WHEN %(categorie)s::VARCHAR = 'sport' THEN NULL
                     ELSE COALESCE(%(type)s::INTEGER,
                                   (SELECT y.id_type_tache FROM type_tache y
                                     WHERE y.categorie = %(categorie)s::VARCHAR
                                     ORDER BY y.ordre, y.id_type_tache LIMIT 1)) END)
        RETURNING *
        """,
        {
            "code": demande.code,
            "libelle": demande.libelle,
            "categorie": demande.categorie,
            "priorite": demande.priorite,
            "duree": demande.duree_minutes,
            "min": demande.periodicite_min_jours,
            "max": demande.periodicite_max_jours,
            "rappel": demande.rappel_journee,
            "hmin": demande.heure_min,
            "hmax": demande.heure_max,
            "machine": demande.utilise_machine,
            "duo": demande.requiert_les_deux,
            "reportable": demande.reportable,
            "defaut": demande.id_utilisateur_defaut,
            # TAC-20 : une tâche créée depuis l'appli s'arrête comme une tâche ajoutée.
            "moi": qui.id_utilisateur,
            "type": demande.id_type_tache,
        },
    )
    assert cree is not None
    # Lot 5 : l'appli demande le replacement dans la même requête. Le
    # déclencher à part est réservé au réseau privé (CNX-5).
    if replacer:
        from api import ordonnanceur
        ordonnanceur.placer()
    return cree


@routeur.patch("/{id_tache}", summary="Modifier une tâche")
def modifier(id_tache: int, demande: ModificationTache, qui: Authentifie) -> dict:
    _exiger_droit(qui, "modifier")
    # Un « pour qui » envoyé vide veut dire « à tour de rôle » : il passe, même
    # nul. Les autres champs vides ne changent rien.
    champs = {nom: valeur for nom, valeur in demande.model_dump(
                  exclude_unset=True,
                  exclude={"id_type_tache", "sans_heure", "heure_min", "heure_max"}).items()
              if valeur is not None or nom == "id_utilisateur_defaut"}
    # CND-4 : une périodicité en jours remplace le rythme, et l'inverse ; le
    # déclencheur de la base recalcule la périodicité d'un rythme.
    if "rythme_nombre" in champs or "rythme_periode" in champs:
        if not ("rythme_nombre" in champs and "rythme_periode" in champs):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail={"code": "rythme_incomplet",
                        "message": "Un rythme dit combien de fois, et par semaine ou par mois"},
            )
        champs.pop("periodicite_min_jours", None)
        champs.pop("periodicite_max_jours", None)
    elif "periodicite_min_jours" in champs or "periodicite_max_jours" in champs:
        champs["rythme_nombre"] = None
        champs["rythme_periode"] = None
    change_l_heure = demande.sans_heure or demande.heure_min is not None
    if not champs and demande.id_type_tache is None and not change_l_heure:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"code": "rien_a_modifier", "message": "Aucun champ fourni"},
        )
    _une_tache(id_tache)

    # Une seule transaction : un type ou une heure refusés n'en laissent pas la
    # moitié en base.
    # La durée part avec l'heure : « à 18h30 » dure exactement la tâche (TAC-23).
    duree = champs.pop("duree_minutes", None) if change_l_heure else None
    with connexion() as conn:
        if champs:
            affectations = ", ".join(f"{nom} = %({nom})s" for nom in champs)
            conn.execute(f"UPDATE tache SET {affectations} WHERE id_tache = %(id_tache)s",
                         {**champs, "id_tache": id_tache})
        if demande.id_type_tache is not None:
            conn.execute("SELECT changer_type_tache(%(t)s, %(y)s)",
                         {"t": id_tache, "y": demande.id_type_tache})
        if change_l_heure:
            conn.execute("SELECT regler_heure_tache(%(t)s, %(hmin)s, %(hmax)s, %(duree)s)",
                         {"t": id_tache,
                          "hmin": None if demande.sans_heure else demande.heure_min,
                          "hmax": None if demande.sans_heure else demande.heure_max,
                          "duree": duree})
    if change_l_heure or "duree_minutes" in champs or "rythme_periode" in champs:
        _replacer()
    return _une_tache(id_tache)


@routeur.delete("/{id_tache}", summary="Désactiver une tâche")
def desactiver(id_tache: int, qui: Authentifie) -> dict:
    _exiger_droit(qui, "modifier")
    # On ne supprime pas : l'historique des occurrences garde son sens.
    executer(
        """
        WITH stop AS (
            UPDATE tache SET active = FALSE WHERE id_tache = %(id)s RETURNING id_tache
        )
        UPDATE occurrence
           SET statut = 'abandonnee', motif = 'Tâche désactivée'
         WHERE id_tache IN (SELECT id_tache FROM stop)
           AND statut IN ('a_placer', 'planifiee', 'notifiee')
        """,
        {"id": id_tache},
    )
    detail = un_seul("SELECT * FROM tache WHERE id_tache = %(id)s", {"id": id_tache})
    if detail is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": f"Tâche {id_tache} inconnue"},
        )
    return detail


# -----------------------------------------------------------------------------
# Les liens entre tâches                                         (TAC-27, TAC-28)
# -----------------------------------------------------------------------------
@routeur.get("/{id_tache}/liens", summary="Ce qui suit, accompagne ou est couvert")
def liens(id_tache: int, qui: Authentifie) -> list[dict]:
    """Les liens des deux côtés : `depuis` vrai quand la tâche est celle de départ.

    La phrase est faite par la base, dans le sens où on la lit (WID-8).
    """
    _une_tache(id_tache)
    return lister(
        """
        SELECT l.sorte, l.id_lien, l.id_de, l.libelle_de, l.id_vers, l.libelle_vers,
               l.delai_min_heures, l.delai_max_heures, l.place, l.mention,
               l.journee_libre, l.bloc, l.delai,
               l.id_de = %(t)s AS depuis,
               CASE WHEN l.id_de = %(t)s THEN l.phrase_depuis ELSE l.phrase_vers END AS phrase,
               CASE WHEN l.id_de = %(t)s THEN l.id_vers ELSE l.id_de END AS id_autre
          FROM v_lien_tache l
         WHERE l.actif AND (l.id_de = %(t)s OR l.id_vers = %(t)s)
         ORDER BY l.id_de <> %(t)s, l.sorte, l.id_lien
        """,
        {"t": id_tache},
    )


@routeur.post("/{id_tache}/liens", status_code=status.HTTP_201_CREATED,
              summary="Relier à une autre tâche")
def lier(id_tache: int, lien: NouveauLien, qui: Authentifie) -> list[dict]:
    _exiger_droit(qui, "modifier")
    executer(
        """SELECT lier_taches(%(sorte)s, %(t)s, %(autre)s, %(dmin)s, %(dmax)s,
                              %(place)s, %(mention)s)""",
        {"sorte": lien.sorte, "t": id_tache, "autre": lien.id_autre,
         "dmin": lien.delai_min_heures, "dmax": lien.delai_max_heures,
         "place": lien.place, "mention": lien.mention},
    )
    _replacer()
    return liens(id_tache, qui)


@routeur.delete("/liens/{sorte}/{id_lien}", summary="Retirer un lien")
def delier(sorte: Literal["ensuite", "meme_jour", "vaut_aussi"], id_lien: int,
           qui: Authentifie) -> dict:
    _exiger_droit(qui, "modifier")
    executer("SELECT delier_taches(%(s)s, %(l)s)", {"s": sorte, "l": id_lien})
    _replacer()
    return {"retire": True}
