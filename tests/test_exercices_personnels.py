"""Un exercice hors catalogue, reconnu par HAL                           (EXO-11)

L'utilisateur tape un nom que le catalogue ne connaît pas. HAL dit si c'est un
exercice du catalogue sous un autre nom, ou le décrit, et il rejoint le
catalogue de ce compte seul. Aucun appel au modèle ne part : sa réponse est
écrite par chaque test.
"""

import json
import uuid

import psycopg
import pytest

from api.coach import fournisseurs, modele, outils
from tests.test_coach import u  # noqa: F401
from tests.test_ensemble import _id, sql, un

HIP_THRUST = {"libelle": "Hip thrust à la Smith", "discipline": "musculation",
              "groupe_principal": "fessiers", "groupes_secondaires": ["ischios", "nez"],
              "materiel": "machine", "unilateral": False, "mesure": "charge_reps",
              "consigne": "Les épaules sur le banc, pousser par les talons."}


@pytest.fixture
def hal(monkeypatch):
    """Ce que HAL répondra, et les noms qu'on lui a fait lire."""
    lus = []

    def repondre(reponse):
        def ecrire(id_utilisateur, systeme, texte, *args, **kwargs):
            lus.append(texte)
            if isinstance(reponse, Exception):
                raise reponse
            return modele.Tour(texte=reponse if isinstance(reponse, str)
                               else json.dumps(reponse, ensure_ascii=False))
        monkeypatch.setattr(fournisseurs, "ecrire", ecrire)
        return lus
    return repondre


def ajouter(client, entetes, libelle, discipline="musculation"):
    return client.post("/exercices", headers=entetes,
                       json={"libelle": libelle, "discipline": discipline})


def test_un_exercice_inconnu_rejoint_le_catalogue_de_celui_qui_l_ajoute(
        client, thomas, lorette, hal):
    lus = hal(f"Voici : {json.dumps(HIP_THRUST, ensure_ascii=False)}")

    rendu = ajouter(client, thomas, "hip trust smith")

    assert rendu.status_code == 201, rendu.json()
    exercice = rendu.json()
    assert exercice["libelle"] == "Hip thrust à la Smith"
    assert exercice["code"] == f"perso_{exercice['id_exercice']}"
    assert (exercice["groupe_principal"], exercice["materiel"], exercice["mesure"]) == \
        ("fessiers", "machine", "charge_reps")
    # Un groupe inventé ne passe pas.
    assert exercice["groupes_secondaires"] == ["ischios"]
    assert exercice["personnel"] is True
    assert "hip trust smith" in lus[0]

    def codes(entetes):
        return {x["code"] for x in client.get("/exercices", headers=entetes).json()}
    assert exercice["code"] in codes(thomas)
    assert exercice["code"] not in codes(lorette)


def test_le_meme_nom_rend_le_meme_exercice_sans_redemander(client, thomas, hal):
    lus = hal(HIP_THRUST)
    premier = ajouter(client, thomas, "Hip thrust à la Smith").json()

    second = ajouter(client, thomas, "hip thrust à la smith").json()

    assert second["id_exercice"] == premier["id_exercice"]
    assert len(lus) == 1
    assert un("SELECT count(*) FROM exercice WHERE id_utilisateur IS NOT NULL") == 1


def test_un_exercice_du_catalogue_sous_un_autre_nom_est_celui_du_catalogue(
        client, thomas, hal):
    hal({"code": "crunch_poulie"})

    rendu = ajouter(client, thomas, "cable crunch").json()

    assert (rendu["code"], rendu["personnel"]) == ("crunch_poulie", False)
    assert un("SELECT count(*) FROM exercice WHERE id_utilisateur IS NOT NULL") == 0


@pytest.mark.parametrize("reponse, message", [
    ({"inconnu": "C'est un plat, pas un exercice."}, "C'est un plat"),
    ({**HIP_THRUST, "materiel": "fusee"}, "pas su reconnaître"),
    ({"code": "code_invente"}, "pas su reconnaître"),
    ("Je ne sais pas.", "pas su reconnaître"),
    (modele.ModeleInjoignable("coupure"), "ne répond pas"),
])
def test_ce_que_hal_ne_reconnait_pas_ne_s_ajoute_pas(client, thomas, hal, reponse, message):
    hal(reponse)

    rendu = ajouter(client, thomas, "blanquette")

    assert rendu.status_code == 422
    assert rendu.json()["code"] == "exercice_non_reconnu"
    assert message in rendu.json()["message"]
    assert un("SELECT count(*) FROM exercice WHERE id_utilisateur IS NOT NULL") == 0


def test_ajoute_depuis_une_seance_de_musculation_il_en_est(client, thomas, hal):
    hal({**HIP_THRUST, "discipline": "cardio"})

    assert ajouter(client, thomas, "Hip thrust").json()["discipline"] == "musculation"


def test_l_exercice_de_l_un_ne_sert_pas_a_l_autre(client, thomas, hal, u):  # noqa: F811
    hal(HIP_THRUST)
    exercice = ajouter(client, thomas, "Hip thrust").json()
    lorette = _id("lorette")

    # Le coach le voit dans le catalogue de Thomas, marqué comme ajouté par lui.
    assert "perso" in outils.lire_catalogue(u, {"groupe": "fessiers"})
    assert exercice["code"] not in outils.lire_catalogue(lorette, {"groupe": "fessiers"})
    # Il peut le mettre dans une séance de Thomas, pas dans une de Lorette.
    exercices = json.dumps([{"code": exercice["code"], "series": 3}])
    assert un("SELECT verifier_exercices(%s, 'musculation', %s, CURRENT_DATE)",
              u, exercices) == [exercice["id_exercice"]]
    with pytest.raises(psycopg.Error, match="Exercice inconnu"):
        sql("SELECT verifier_exercices(%s, 'musculation', %s, CURRENT_DATE)",
            lorette, exercices)
    # Et Lorette ne le saisit pas dans sa séance libre.
    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE id_utilisateur = %s", lorette)
    libre = un("SELECT creer_seance_libre(%s, 'musculation', now(), 50, NULL, FALSE, %s)",
               lorette, uuid.uuid4())
    with pytest.raises(psycopg.Error, match="pas au catalogue de ce compte"):
        sql("SELECT enregistrer_serie(%s, %s, %s, %s, 1, 40, 10)",
            lorette, libre, exercice["id_exercice"], uuid.uuid4())
