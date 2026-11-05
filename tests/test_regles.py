"""Les règles typées, première sorte « a_plusieurs »                  (lot A du lot D)

Ce qu'on dit d'une tâche devient une règle que le système garde : une sorte prise
dans une liste fermée, avec ses paramètres, que la base vérifie (RGL-1, RGL-2).
Une règle changée garde sa version d'avant (RGL-10), suit sa tâche (RGL-11) et se
lit en phrase (RGL-9). HAL l'écrit, la lit et la retire. Le grand nettoyage, qui
« se fait à deux » dans sa description depuis la 086, a désormais la règle.

Dans ce lot, la règle n'a encore aucun effet sur le placement ni la balance.
"""

import psycopg
import pytest

from api.coach import foyer as hal_foyer
from api.coach.outils import RefusOutil
from tests.test_ensemble import _id, sql, un


def _nouvelle(libelle: str = "Nettoyer la hotte") -> int:
    return un("SELECT creer_tache(p_libelle => %s, p_acteur => %s, p_tous_les_jours => 14)",
              libelle, _id("thomas"))


def _regle(tache: int, membres=2, phrase: str = "Ça se fait à deux.") -> int:
    return un("SELECT enregistrer_regle(%s, 'a_plusieurs', %s::jsonb, %s, %s)",
              tache, f'{{"membres": {membres}}}', phrase, _id("thomas"))


def _regles(tache: int) -> list[dict]:
    return sql("SELECT * FROM v_regle WHERE id_tache = %s ORDER BY id_regle", tache)


# ---------------------------------------------------------------------------
# Le catalogue et la vérification par la base                     RGL-1, RGL-2
# ---------------------------------------------------------------------------

def test_la_sorte_a_plusieurs_est_au_catalogue(base):
    (sorte,) = sql("SELECT * FROM sorte_regle WHERE code = 'a_plusieurs'")
    assert sorte["cible"] == "tache"
    assert sorte["pose_occurrence"] is False
    assert sorte["parametres"]["membres"]["maximum"] == 2


def test_une_regle_valide_se_lit_en_phrase(base):
    t = _nouvelle()
    _regle(t)

    (regle,) = _regles(t)
    assert regle["sorte"] == "a_plusieurs"
    assert regle["phrase"] == "Ça se fait à deux."
    assert regle["parametres"] == {"membres": 2}
    assert regle["dite_par_nom"] == "Thomas"
    assert regle["en_vigueur"] is True


@pytest.mark.parametrize("sorte, parametres, phrase", [
    ("a_plusieurs", '{"membres": 3}', "À trois"),
    ("a_plusieurs", '{"membres": 1}', "Seul"),
    ("a_plusieurs", '{"membres": 2.5}', "À deux et demi"),
    ("a_plusieurs", '{"membres": "deux"}', "À deux"),
    ("a_plusieurs", '{}', "À deux"),
    ("a_plusieurs", '{"membres": 2, "autre": 1}', "À deux"),
    ("inconnue", '{"membres": 2}', "À deux"),
    ("a_plusieurs", '{"membres": 2}', "   "),
])
def test_la_base_refuse_une_regle_invalide(base, sorte, parametres, phrase):
    t = _nouvelle()
    with pytest.raises(psycopg.errors.CheckViolation):
        un("SELECT enregistrer_regle(%s, %s, %s::jsonb, %s, %s)",
           t, sorte, parametres, phrase, _id("thomas"))
    assert un("SELECT count(*) FROM regle WHERE id_tache = %s", t) == 0


def test_une_regle_sur_une_tache_inconnue_est_refusee(base):
    with pytest.raises(psycopg.errors.CheckViolation):
        _regle(999999)


# ---------------------------------------------------------------------------
# Les versions                                                         RGL-10
# ---------------------------------------------------------------------------

def test_une_regle_changee_garde_sa_version_d_avant(base):
    t = _nouvelle()
    a = _regle(t)
    b = _regle(t, phrase="À deux, toujours.")
    assert b != a

    (avant,) = sql("SELECT * FROM regle WHERE id_regle = %s", a)
    assert avant["etat"] == "retiree"
    assert avant["retiree_le"] is not None
    assert avant["remplacee_par"] == b
    assert un("SELECT etat FROM regle WHERE id_regle = %s", b) == "active"
    assert [r["id_regle"] for r in _regles(t)] == [b]

    # La même règle redite ne crée rien.
    assert _regle(t, phrase="À deux, toujours.") == b
    assert un("SELECT count(*) FROM regle WHERE id_tache = %s", t) == 2


def test_retirer_une_regle_la_garde_en_trace(base):
    t = _nouvelle()
    a = _regle(t)

    assert un("SELECT retirer_regle(%s)", a) is True
    assert _regles(t) == []
    assert un("SELECT etat FROM regle WHERE id_regle = %s", a) == "retiree"
    assert un("SELECT retirer_regle(%s)", a) is False
    assert un("SELECT retirer_regle(999999999)") is False


# ---------------------------------------------------------------------------
# La règle suit sa tâche                                               RGL-11
# ---------------------------------------------------------------------------

def test_la_regle_suit_sa_tache(client, thomas):
    t = _nouvelle()
    _regle(t)

    assert client.delete(f"/taches/{t}", headers=thomas).status_code == 200
    assert [r["en_vigueur"] for r in _regles(t)] == [False]

    assert client.post(f"/taches/{t}/reprendre", headers=thomas).status_code == 200
    assert [r["en_vigueur"] for r in _regles(t)] == [True]

    client.delete(f"/taches/{t}", headers=thomas)
    assert client.delete(f"/taches/{t}/definitivement", headers=thomas).status_code == 200
    assert un("SELECT count(*) FROM regle WHERE id_tache = %s", t) == 0


# ---------------------------------------------------------------------------
# La reprise du grand nettoyage
# ---------------------------------------------------------------------------

def test_le_grand_nettoyage_a_sa_regle_apres_la_migration(base):
    g = un("SELECT essais.tache_de('GRAND_NETTOYAGE')")

    assert [(r["sorte"], r["parametres"]) for r in _regles(g)] == [("a_plusieurs", {"membres": 2})]
    texte = un("SELECT texte FROM v_description_tache WHERE id_tache = %s", g)
    assert texte is None or "à deux" not in texte


# ---------------------------------------------------------------------------
# L'API montre les règles en phrase                                     RGL-9
# ---------------------------------------------------------------------------

def test_l_api_montre_les_regles_de_la_tache(client, thomas):
    avec, sans = _nouvelle(), _nouvelle("Nettoyer le four")
    _regle(avec)

    taches = {x["id_tache"]: x for x in client.get("/taches", headers=thomas).json()}

    (regle,) = taches[avec]["regles"]
    assert regle["sorte"] == "a_plusieurs"
    assert regle["phrase"] == "Ça se fait à deux."
    assert regle["parametres"] == {"membres": 2}
    assert regle["dite_par"] == "Thomas"
    assert taches[sans]["regles"] == []
    assert len(taches[un("SELECT essais.tache_de('GRAND_NETTOYAGE')")]["regles"]) == 1


# ---------------------------------------------------------------------------
# HAL écrit, lit et retire une règle, sur n'importe quelle tâche     TAC-29
# ---------------------------------------------------------------------------

def test_hal_ecrit_lit_et_retire_une_regle_sur_n_importe_quelle_tache(base):
    u, t = _id("thomas"), _nouvelle()

    ecrite = hal_foyer.ecrire_regle(u, {"id_tache": t, "sorte": "a_plusieurs",
                                        "parametres": {"membres": 2}, "phrase": "À deux"})
    assert ecrite["fait"] == "règle enregistrée"

    lu = hal_foyer.lire_regles(u, {"id_tache": t})
    assert [r["id_regle"] for r in lu["regles"]] == [ecrite["id_regle"]]
    assert "a_plusieurs" in {s["code"] for s in lu["sortes"]}

    assert hal_foyer.retirer_regle(u, {"id_regle": ecrite["id_regle"]})["fait"] == "règle retirée"
    with pytest.raises(RefusOutil):
        hal_foyer.retirer_regle(u, {"id_regle": ecrite["id_regle"]})
    with pytest.raises(psycopg.errors.CheckViolation):
        hal_foyer.ecrire_regle(u, {"id_tache": t, "sorte": "a_plusieurs",
                                   "parametres": {"membres": 3}, "phrase": "À trois"})
    with pytest.raises(RefusOutil):
        hal_foyer.ecrire_regle(u, {"id_tache": t, "sorte": "a_plusieurs",
                                   "parametres": "2", "phrase": "À deux"})


def test_les_outils_de_regles_sont_ouverts_au_moment_maison(base):
    regles = {"lire_regles", "ecrire_regle", "retirer_regle"}
    assert regles <= {o.nom for o in hal_foyer.outils_du_moment("maison")}
    assert not regles & {o.nom for o in hal_foyer.outils_du_moment("verification")}
