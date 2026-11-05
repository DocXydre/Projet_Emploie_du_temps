"""« C'est fait » pour une tâche faite en plus, qui n'existait pas       (EXE-17)

La tâche est créée ponctuelle et arrêtée, son occurrence est faite à la date
dite au nom de celui qui déclare. Ces tests appellent la fonction SQL ; la
route est testée dans test_repartition.py.
"""

import psycopg
import pytest

from api.ordonnanceur import placer
from tests.conftest import _url


def _sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row, autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def _un(requete: str, *parametres):
    lignes = _sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def _id(pseudo: str) -> int:
    return _un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)


def _menage() -> int:
    return _un("SELECT id_type_tache FROM type_tache WHERE base = 'menage'")


def _minutes_faites(pseudo: str) -> int:
    """L'équilibre de /appli/aujourdhui : les minutes faites sur sept jours."""
    return _un(
        "SELECT COALESCE(sum(o.duree_minutes), 0)::INTEGER FROM v_occurrence o "
        "WHERE o.id_utilisateur = %s AND o.statut = 'faite' AND o.categorie <> 'sport' "
        "AND o.date_faite > now() - INTERVAL '7 days'",
        _id(pseudo),
    )


def test_la_tache_est_creee_ponctuelle_et_arretee_et_son_occurrence_faite_a_la_date_dite():
    thomas = _id("thomas")
    hier = _un("SELECT now() - INTERVAL '1 day'")

    numero = _un(
        "SELECT declarer_faite_en_plus(%s, %s, %s, NULL, %s)",
        thomas,
        "  Détartrer   la bouilloire ",
        _menage(),
        hier,
    )

    tache = _sql(
        "SELECT t.libelle, t.revient, t.active, t.ajoutee_par, t.id_type_tache, "
        "t.duree_minutes, t.priorite, y.duree_minutes AS duree_type, y.priorite AS priorite_type "
        "FROM occurrence o JOIN tache t USING (id_tache) "
        "JOIN type_tache y ON y.id_type_tache = t.id_type_tache "
        "WHERE o.id_occurrence = %s",
        numero,
    )[0]
    assert tache["libelle"] == "Détartrer la bouilloire"
    assert tache["revient"] == "dates" and tache["active"] is False
    assert tache["ajoutee_par"] == thomas and tache["id_type_tache"] == _menage()
    assert tache["duree_minutes"] == tache["duree_type"]
    assert tache["priorite"] == tache["priorite_type"]
    occurrence = _sql(
        "SELECT statut, id_utilisateur, origine, date_faite FROM occurrence "
        "WHERE id_occurrence = %s",
        numero,
    )[0]
    assert occurrence == {
        "statut": "faite",
        "id_utilisateur": thomas,
        "origine": "manuelle",
        "date_faite": hier,
    }


def test_sans_date_ni_type_c_est_maintenant_et_le_type_menage():
    numero = _un("SELECT declarer_faite_en_plus(%s, 'Trier les piles')", _id("thomas"))

    assert (
        _un(
            "SELECT date_faite > now() - INTERVAL '1 minute' AND date_faite <= now() "
            "FROM occurrence WHERE id_occurrence = %s",
            numero,
        )
        is True
    )
    assert (
        _un(
            "SELECT t.id_type_tache FROM occurrence o JOIN tache t USING (id_tache) "
            "WHERE o.id_occurrence = %s",
            numero,
        )
        == _menage()
    )


def test_une_duree_donnee_remplace_celle_du_type():
    numero = _un("SELECT declarer_faite_en_plus(%s, 'Trier les piles', NULL, 45)", _id("thomas"))

    assert (
        _un(
            "SELECT t.duree_minutes FROM occurrence o JOIN tache t USING (id_tache) "
            "WHERE o.id_occurrence = %s",
            numero,
        )
        == 45
    )


def test_elle_compte_dans_l_equilibre_de_celui_qui_l_a_faite():
    avant = {p: _minutes_faites(p) for p in ("thomas", "lorette")}

    numero = _un("SELECT declarer_faite_en_plus(%s, 'Trier les piles', NULL, 45)", _id("lorette"))

    assert _minutes_faites("lorette") == avant["lorette"] + 45
    assert _minutes_faites("thomas") == avant["thomas"]
    assert _un("SELECT id_utilisateur FROM occurrence WHERE id_occurrence = %s", numero) == _id(
        "lorette"
    )


def test_elle_n_apparait_pas_au_planning_a_venir():
    numero = _un("SELECT declarer_faite_en_plus(%s, 'Trier les piles')", _id("thomas"))
    tache = _un("SELECT id_tache FROM occurrence WHERE id_occurrence = %s", numero)

    placer()

    assert _un("SELECT count(*) FROM occurrence WHERE id_tache = %s", tache) == 1
    assert (
        _un(
            "SELECT count(*) FROM occurrence WHERE id_tache = %s "
            "AND statut IN ('a_placer', 'planifiee', 'notifiee')",
            tache,
        )
        == 0
    )


@pytest.mark.parametrize(
    "appel, motif",
    [
        ("declarer_faite_en_plus(%s, 'x')", "2 à 100"),
        (
            "declarer_faite_en_plus(%s, 'Trier les piles', NULL, NULL, now() + INTERVAL '1 hour')",
            "pas encore",
        ),
        ("declarer_faite_en_plus(%s, 'Trier les piles', 999999)", "type de tâche"),
        ("declarer_faite_en_plus(%s, 'Trier les piles', NULL, 0)", "durée"),
        ("declarer_faite_en_plus(%s, 'Trier les piles', NULL, 481)", "durée"),
    ],
)
def test_les_refus_ne_creent_rien(appel, motif):
    with pytest.raises(psycopg.errors.CheckViolation, match=motif):
        _sql(f"SELECT {appel}", _id("thomas"))

    assert _un("SELECT count(*) FROM tache WHERE ajoutee_par IS NOT NULL") == 0
