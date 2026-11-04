"""Les tâches à plusieurs : le placement (lot B1)"""

from datetime import time, timedelta

from api.ordonnanceur import placer
from tests.test_ensemble import _id, absent, minuit, sql, un
from tests.test_regles import _regle


def _horaire(avec_regle: bool = True) -> int:
    """Une tâche du formulaire, d'une heure, entre 18h et 21h, tous les 14 jours."""
    t = un(
        "SELECT creer_tache(p_libelle => 'Nettoyer la hotte', p_acteur => %s, "
        "p_duree_minutes => 60, p_tous_les_jours => 14, "
        "p_heure_min => '18:00', p_heure_max => '21:00')",
        _id("thomas"),
    )
    if avec_regle:
        _regle(t)
    return t


def _deux() -> list[int]:
    return sorted([_id("thomas"), _id("lorette")])


def _occurrences(tache: int) -> list[dict]:
    return sql(
        """SELECT o.id_occurrence, o.id_utilisateur, o.statut, o.creneau, o.motif,
                         (lower(o.creneau) AT TIME ZONE 'Europe/Paris')::time AS debut,
                         (upper(o.creneau) AT TIME ZONE 'Europe/Paris')::time AS fin,
                         ARRAY(SELECT p.id_utilisateur FROM occurrence_participant p
                                WHERE p.id_occurrence = o.id_occurrence
                                ORDER BY p.id_utilisateur) AS participants
                    FROM occurrence o WHERE o.id_tache = %s
                   ORDER BY lower(o.fenetre), o.id_occurrence""",
        tache,
    )


def _posees(tache: int) -> list[dict]:
    return [o for o in _occurrences(tache) if o["statut"] == "planifiee"]


def test_une_tache_a_plusieurs_est_posee_pour_les_deux_au_meme_creneau(base):
    t = _horaire()
    placer()
    posees = _posees(t)
    assert posees
    for o in posees:
        assert o["participants"] == _deux()
        assert o["id_utilisateur"] == _deux()[0]
        assert time(18, 0) <= o["debut"] and o["fin"] <= time(21, 0)
        assert o["creneau"].upper - o["creneau"].lower == timedelta(hours=1)
        # Libre pour les deux : aucune autre occurrence ne chevauche ce créneau
        assert (
            un(
                "SELECT count(*) FROM occurrence a "
                "WHERE a.id_occurrence <> %s "
                "  AND a.statut IN ('planifiee','notifiee') "
                "  AND NOT a.rappel_journee "
                "  AND a.creneau && (SELECT creneau FROM occurrence WHERE id_occurrence = %s) "
                "  AND a.id_utilisateur IN (SELECT id_utilisateur FROM utilisateur WHERE actif)",
                o["id_occurrence"],
                o["id_occurrence"],
            )
            == 0
        )


def test_sans_creneau_commun_elle_reste_a_placer_avec_un_motif(base):
    t = _horaire()
    absent("thomas", minuit(0), minuit(40))
    placer()
    # Ne garder que les occurrences que le placement a pu voir :
    # celles dont la fenêtre commence avant now() + horizon_jours (35 par défaut)
    occ = sql(
        """SELECT o.id_occurrence, o.id_utilisateur, o.statut, o.creneau, o.motif,
                         (lower(o.creneau) AT TIME ZONE 'Europe/Paris')::time AS debut,
                         (upper(o.creneau) AT TIME ZONE 'Europe/Paris')::time AS fin,
                         ARRAY(SELECT p.id_utilisateur FROM occurrence_participant p
                                WHERE p.id_occurrence = o.id_occurrence
                                ORDER BY p.id_utilisateur) AS participants
                    FROM occurrence o
                   WHERE o.id_tache = %s
                     AND lower(o.fenetre) < now() + make_interval(days => 35)
                   ORDER BY lower(o.fenetre), o.id_occurrence""",
        t,
    )
    assert occ
    for o in occ:
        assert o["statut"] == "a_placer"
        assert o["participants"] == []
        assert o["id_utilisateur"] is None
        assert "Ça se fait à deux." in o["motif"]


def test_poser_la_regle_apres_coup_refait_les_occurrences(base):
    t = _horaire(avec_regle=False)
    placer()
    avant = _posees(t)
    assert avant
    for o in avant:
        assert o["participants"] == []
    _regle(t)
    placer()
    apres = _posees(t)
    assert apres
    for o in apres:
        assert o["participants"] == _deux()


def test_retirer_la_regle_rend_les_occurrences_suivantes_ordinaires(base):
    t = _horaire()
    placer()
    assert _posees(t)
    r = un("SELECT id_regle FROM v_regle WHERE id_tache = %s", t)
    assert un("SELECT retirer_regle(%s)", r) is True
    placer()
    apres = _posees(t)
    assert apres
    for o in apres:
        assert o["participants"] == []
        assert o["id_utilisateur"] is not None


def test_un_foyer_d_une_personne_garde_les_taches_ordinaires(base):
    sql("UPDATE utilisateur SET actif = FALSE WHERE pseudo = 'lorette'")
    t = _horaire()
    placer()
    posees = _posees(t)
    assert posees
    for o in posees:
        assert o["participants"] == []
        assert o["id_utilisateur"] == _id("thomas")


def test_le_grand_nettoyage_est_pose_pour_les_deux(base):
    placer()
    g = un("SELECT essais.tache_de('GRAND_NETTOYAGE')")
    posees = _posees(g)
    assert posees
    for o in posees:
        assert o["participants"] == _deux()
        assert time(13, 0) <= o["debut"]
        assert o["fin"] <= time(19, 0)
        assert o["creneau"].upper - o["creneau"].lower == timedelta(minutes=120)
