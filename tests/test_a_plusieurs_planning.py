"""Les tâches à plusieurs : le planning et le bilan (lot B2)"""

from tests.test_ensemble import _id, sql, un
from tests.test_regles import _nouvelle, _regle


def _aujourdhui(heure: int, a_deux: bool, statut: str = "planifiee") -> int:
    """Une occurrence de « Nettoyer la hotte » aujourd'hui de `heure`h à `heure`+1h, à Thomas."""
    t = _nouvelle()
    if a_deux:
        _regle(t)
    numero = un(
        "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut, origine, "
        "rappel_journee) "
        "VALUES (%s, %s, tstzrange(debut_jour(jour_de(now())), "
        "debut_jour(jour_de(now()) + 1), '[)'), "
        f"tstzrange(debut_jour(jour_de(now())) + INTERVAL '{heure} hours', "
        f"debut_jour(jour_de(now())) + INTERVAL '{heure + 1} hours', '[)'), "
        "%s, 'manuelle', FALSE) RETURNING id_occurrence",
        t,
        _id("thomas"),
        statut,
    )
    if a_deux:
        sql(
            "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) "
            "VALUES (%s, %s), (%s, %s)",
            numero,
            _id("thomas"),
            numero,
            _id("lorette"),
        )
    return numero


def _lignes(numero: int) -> list[dict]:
    return sql(
        "SELECT id_utilisateur, libelle FROM v_planning "
        "WHERE nature = 'tache' AND id = %s ORDER BY id_utilisateur",
        numero,
    )


# ---------------------------------------------------------------------------
# Le planning : une ligne par participant                                RGL-20
# ---------------------------------------------------------------------------


def test_une_tache_a_deux_est_au_planning_des_deux(base):
    numero = _aujourdhui(10, True)
    lignes = _lignes(numero)
    assert len(lignes) == 2
    assert [ligne["id_utilisateur"] for ligne in lignes] == sorted([_id("thomas"), _id("lorette")])
    assert [ligne["libelle"] for ligne in lignes] == ["Nettoyer la hotte (à deux)"] * 2


def test_une_tache_ordinaire_reste_une_ligne_sans_mention(base):
    numero = _aujourdhui(10, False)
    (ligne,) = _lignes(numero)
    assert ligne["id_utilisateur"] == _id("thomas")
    assert ligne["libelle"] == "Nettoyer la hotte"


# ---------------------------------------------------------------------------
# Le bilan du matin : chacun des deux voit la tâche                      RGL-20
# ---------------------------------------------------------------------------


def test_le_bilan_du_matin_des_deux_montre_la_tache(base):
    numero = _aujourdhui(10, True)
    for pseudo in ("thomas", "lorette"):
        assert un("SELECT bilan_du_matin_de(%s)", _id(pseudo)) == 1
        contenu = un(
            "SELECT contenu FROM notification WHERE id_utilisateur = %s AND type = 'bilan'",
            _id(pseudo),
        )
        assert "Nettoyer la hotte (à deux)" in contenu
    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", numero) == "notifiee"
