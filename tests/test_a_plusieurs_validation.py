"""Les tâches à plusieurs : la validation (lot B2)"""

from tests.test_ensemble import _id, sql, un
from tests.test_regles import _nouvelle, _regle


def _occurrence(tache: int, pseudo: str = "thomas") -> int:
    return un(
        "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine) "
        "VALUES (%s, %s, "
        "tstzrange(now() - INTERVAL '1 day', now() + INTERVAL '3 days', '[)'), "
        "'manuelle') "
        "RETURNING id_occurrence",
        tache,
        _id(pseudo),
    )


def _a_deux() -> int:
    t = _nouvelle()
    _regle(t)
    numero = _occurrence(t)
    sql(
        "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) "
        "VALUES (%s, %s), (%s, %s)",
        numero,
        _id("thomas"),
        numero,
        _id("lorette"),
    )
    return numero


def _alertes(pseudo: str, numero: int) -> list[str]:
    return [
        ligne["contenu"]
        for ligne in sql(
            "SELECT contenu FROM notification "
            "WHERE id_utilisateur = %s AND id_occurrence = %s AND type = 'alerte' "
            "ORDER BY id_notification",
            _id(pseudo),
            numero,
        )
    ]


def _sentinelle() -> int:
    """Un aspirateur ordinaire de Thomas, demain 10h, que reequilibrer() libérerait."""
    return un(
        "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, "
        "statut, origine, rappel_journee) "
        "VALUES (essais.tache_de('ASPIRATEUR'), %s, "
        "tstzrange(debut_jour(jour_de(now()) + 1), "
        "debut_jour(jour_de(now()) + 2), '[)'), "
        "tstzrange(debut_jour(jour_de(now()) + 1) + INTERVAL '10 hours', "
        "debut_jour(jour_de(now()) + 1) + INTERVAL '11 hours', '[)'), "
        "'planifiee', 'manuelle', FALSE) RETURNING id_occurrence",
        _id("thomas"),
    )


def test_le_second_participant_valide_pour_tous(base):
    numero = _a_deux()
    sql("SELECT valider_occurrence(%s, %s, NULL)", numero, _id("lorette"))

    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", numero) == "faite"
    assert un("SELECT count(*) FROM occurrence WHERE id_occurrence_source = %s", numero) == 1

    nom = un("SELECT nom FROM utilisateur WHERE pseudo = 'lorette'")
    assert _alertes("thomas", numero) == [f"✅ « Nettoyer la hotte » est noté fait par {nom}."]
    assert _alertes("lorette", numero) == []
    assert un("SELECT count(*) FROM notification WHERE contenu LIKE '%à ta place%'") == 0


def test_le_premier_participant_valide_et_previent_l_autre(base):
    numero = _a_deux()
    sql("SELECT valider_occurrence(%s, %s, NULL)", numero, _id("thomas"))

    nom = un("SELECT nom FROM utilisateur WHERE pseudo = 'thomas'")
    assert _alertes("lorette", numero) == [f"✅ « Nettoyer la hotte » est noté fait par {nom}."]
    assert _alertes("thomas", numero) == []


def test_valider_a_plusieurs_ne_rejoue_pas_la_repartition(base):
    numero = _a_deux()
    s = _sentinelle()
    sql("SELECT valider_occurrence(%s, %s, NULL)", numero, _id("lorette"))

    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", s) == "planifiee"
    assert un("SELECT id_utilisateur FROM occurrence WHERE id_occurrence = %s", s) == _id("thomas")


def test_une_tache_ordinaire_garde_le_message_et_le_reequilibrage(base):
    t = _nouvelle()
    numero = _occurrence(t)
    s = _sentinelle()
    sql("SELECT valider_occurrence(%s, %s, NULL)", numero, _id("lorette"))

    alertes = _alertes("thomas", numero)
    assert len(alertes) == 1
    assert "a fait « Nettoyer la hotte » à ta place" in alertes[0]

    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", s) == "a_placer"
    assert un("SELECT id_utilisateur FROM occurrence WHERE id_occurrence = %s", s) is None
