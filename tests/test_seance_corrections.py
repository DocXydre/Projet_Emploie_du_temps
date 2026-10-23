"""Corriger une séance de musculation en cours : changer d'exercice sans perdre
ses séries, annuler une série, retirer un exercice (SAI-22)."""

# ruff: noqa: F811 (la fixture u de test_coach est importée puis demandée)

import uuid
from datetime import datetime, timedelta

from tests.test_coach import u  # noqa: F401
from tests.test_ensemble import PARIS, sql, un


def _libre(u, cle):
    return un("SELECT creer_seance_libre(%s, 'musculation', now() - INTERVAL '20 minutes', "
              "50, NULL, FALSE, %s)", u, cle)


def _series(client, entete, chemin, code, combien):
    cles = [str(uuid.uuid4()) for _ in range(combien)]
    debut = datetime.now(PARIS).replace(microsecond=0) - timedelta(minutes=15)
    rendu = client.post(chemin, headers=entete, json=[
        {"code": code, "cle_client": cle, "numero": n + 1, "charge_kg": 14, "repetitions": 10,
         "saisie_le": (debut + timedelta(minutes=2 * n)).isoformat()}
        for n, cle in enumerate(cles)])
    assert rendu.status_code == 200, rendu.text
    assert all(s["etat"] != "refusee" for s in rendu.json()["series"]), rendu.text
    return cles


def test_les_series_suivent_l_exercice_choisi(client, thomas, u):
    seance = _libre(u, uuid.uuid4())
    deja = _series(client, thomas, f"/seances/{seance}/series", "curl_barre", 1)
    trompe = _series(client, thomas, f"/seances/{seance}/series", "curl_marteau", 2)

    rendu = client.post(f"/seances/{seance}/series/changer-exercice", headers=thomas,
                        json={"cles": trompe, "code": "curl_barre"})
    assert rendu.status_code == 200, rendu.text
    assert rendu.json() == {"deplacees": 2}
    lignes = sql("""SELECT e.code, ss.numero FROM serie_saisie ss
                      JOIN exercice e USING (id_exercice)
                     WHERE ss.id_occurrence = %s ORDER BY ss.numero""", seance)
    # Numérotées à la suite de celle que l'exercice choisi avait déjà.
    assert lignes == [{"code": "curl_barre", "numero": n} for n in (1, 2, 3)]
    assert deja

    # Un exercice qui se note en durée ne reçoit pas des séries en répétitions.
    refus = client.post(f"/seances/{seance}/series/changer-exercice", headers=thomas,
                        json={"cles": trompe, "code": "planche"})
    assert refus.status_code >= 400
    assert un("SELECT count(*) FROM serie_saisie WHERE id_occurrence = %s "
              "AND id_exercice = (SELECT id_exercice FROM exercice WHERE code = 'planche')",
              seance) == 0


def test_une_seance_libre_se_corrige_par_sa_cle(client, thomas, lorette, u):
    cle = uuid.uuid4()
    seance = _libre(u, cle)
    series = _series(client, thomas, f"/seances/par-cle/{cle}/series", "curl_marteau", 3)

    deplace = client.post(f"/seances/par-cle/{cle}/series/changer-exercice", headers=thomas,
                          json={"cles": series, "code": "curl_barre"})
    assert deplace.json() == {"deplacees": 3}
    # Annuler la dernière série, puis retirer l'exercice : tout part.
    assert client.post(f"/seances/par-cle/{cle}/annuler-saisie", headers=thomas,
                       json={"cles": series[-1:]}).json() == {"retirees": 1}
    assert client.post(f"/seances/par-cle/{cle}/annuler-saisie", headers=thomas,
                       json={"cles": series}).json() == {"retirees": 2}
    assert un("SELECT count(*) FROM serie_saisie WHERE id_occurrence = %s", seance) == 0
    # Lorette ne touche pas aux séances de Thomas.
    assert client.post(f"/seances/par-cle/{cle}/annuler-saisie", headers=lorette,
                       json={"cles": series}).status_code == 404


def test_une_serie_figee_ne_change_pas_d_exercice(client, thomas, u):
    seance = _libre(u, uuid.uuid4())
    series = _series(client, thomas, f"/seances/{seance}/series", "curl_marteau", 1)
    sql("UPDATE serie_saisie SET figee = TRUE WHERE id_occurrence = %s", seance)
    rendu = client.post(f"/seances/{seance}/series/changer-exercice", headers=thomas,
                        json={"cles": series, "code": "curl_barre"})
    assert rendu.status_code >= 400 and "figée" in rendu.text
