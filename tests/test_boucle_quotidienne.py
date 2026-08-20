"""Bilan du matin, relance du soir, report d'office.

C'est la boucle qui décide si le système sert à quelque chose : sans elle, le
planning existe mais personne ne le regarde.
"""

from datetime import UTC, datetime, timedelta

import psycopg

from tests.conftest import _url


def notifications(statut: str | None = None) -> list[dict]:
    filtre = f"WHERE statut = '{statut}'" if statut else ""
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        return conn.execute(
            f"SELECT type, contenu, statut, id_occurrence FROM notification {filtre} "
            f"ORDER BY id_notification"
        ).fetchall()


def forcer_au_jour_meme(code_tache: str) -> int:
    """Place une occurrence aujourd'hui, comme le ferait le moteur."""
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row, autocommit=True) as conn:
        ligne = conn.execute(
            """
            UPDATE occurrence o
               SET creneau = tstzrange(debut_jour(jour_de(now())),
                                       debut_jour(jour_de(now()) + 1), '[)'),
                   fenetre = tstzrange(debut_jour(jour_de(now())),
                                       debut_jour(jour_de(now()) + 2), '[)'),
                   statut  = 'planifiee'
              FROM tache t
             WHERE t.id_tache = o.id_tache
               AND t.code = %s
               AND o.statut IN ('a_placer', 'planifiee')
            RETURNING o.id_occurrence
            """,
            (code_tache,),
        ).fetchone()
    assert ligne is not None, f"aucune occurrence de {code_tache} à placer"
    return ligne["id_occurrence"]


# ---------------------------------------------------------------------------
# Bilan du matin
# ---------------------------------------------------------------------------

def test_le_bilan_annonce_la_journee_et_fige_les_creneaux(client, thomas):
    client.post("/planning/placer", headers=thomas)
    identifiant = forcer_au_jour_meme("ASPIRATEUR")

    creees = client.post("/notifications/bilan", headers=thomas).json()["creees"]
    assert creees >= 1

    bilans = [n for n in notifications() if n["type"] == "bilan"]
    assert bilans
    assert "Passer l'aspirateur" in bilans[0]["contenu"]

    # R19 : le créneau communiqué est figé, il ne bougera plus au replacement.
    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] == "notifiee"


def test_un_bilan_vide_n_est_pas_envoye(client, thomas):
    # Rien n'est placé et aucune source n'est en panne : se taire vaut mieux
    # qu'un message quotidien inutile, qui ferait couper les notifications en
    # une semaine.
    for code in ("IDMC_ICS", "MCDO"):
        client.patch(f"/sources/{code}", headers=thomas, json={"active": False})

    creees = client.post("/notifications/bilan", headers=thomas).json()["creees"]
    assert creees == 0
    assert notifications() == []


def test_le_bilan_signale_les_taches_sans_creneau(client, thomas):
    # Une journée entièrement occupée : le moteur ne peut rien placer.
    debut = datetime.now(UTC).replace(hour=0, minute=0, second=0, microsecond=0)
    for jour in range(0, 25):
        client.post("/occupations", headers=thomas, json={
            "type": "cours", "libelle": "Journée pleine",
            "debut": (debut + timedelta(days=jour)).isoformat(),
            "fin": (debut + timedelta(days=jour + 1)).isoformat(),
        })

    client.post("/planning/placer", headers=thomas)
    client.post("/notifications/bilan", headers=thomas)

    bilans = [n for n in notifications() if n["type"] == "bilan"]
    assert bilans
    assert "Sans créneau" in bilans[0]["contenu"]


def test_le_bilan_previent_l_administrateur_des_pannes(client, thomas):
    # IDMC_ICS est active et n'a jamais été collectée : elle est en panne.
    client.post("/planning/placer", headers=thomas)
    forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)

    bilans = [n for n in notifications() if n["type"] == "bilan"]
    assert any("Collecte en panne" in n["contenu"] for n in bilans)


def test_seul_l_administrateur_declenche_le_bilan(client, lorette):
    assert client.post("/notifications/bilan", headers=lorette).status_code == 403


# ---------------------------------------------------------------------------
# Relance du soir
# ---------------------------------------------------------------------------

def test_la_relance_cible_les_taches_du_jour_non_faites(client, thomas):
    client.post("/planning/placer", headers=thomas)
    identifiant = forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)

    creees = client.post("/notifications/relance", headers=thomas).json()["creees"]
    assert creees >= 1

    rappels = [n for n in notifications() if n["type"] == "rappel"]
    assert any(n["id_occurrence"] == identifiant for n in rappels)
    # Un rappel porte son occurrence : c'est ce qui permettra au bot d'y
    # accrocher ses boutons.
    assert all(n["id_occurrence"] is not None for n in rappels)


def test_une_tache_deja_faite_n_est_pas_relancee(client, thomas):
    client.post("/planning/placer", headers=thomas)
    identifiant = forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)
    client.post(f"/occurrences/{identifiant}/valider", headers=thomas, json={})

    client.post("/notifications/relance", headers=thomas)

    rappels = [n for n in notifications() if n["type"] == "rappel"]
    assert all(n["id_occurrence"] != identifiant for n in rappels)


def test_la_relance_ne_double_pas_le_meme_soir(client, thomas):
    client.post("/planning/placer", headers=thomas)
    forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)

    premiere = client.post("/notifications/relance", headers=thomas).json()["creees"]
    seconde = client.post("/notifications/relance", headers=thomas).json()["creees"]

    assert premiere >= 1
    assert seconde == 0


# ---------------------------------------------------------------------------
# File d'attente
# ---------------------------------------------------------------------------

def test_la_file_expose_ce_que_le_bot_doit_envoyer(client, thomas):
    client.post("/planning/placer", headers=thomas)
    identifiant = forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)
    client.post("/notifications/relance", headers=thomas)

    file = client.get("/notifications", headers=thomas).json()
    assert file

    rappel = next(n for n in file if n["id_occurrence"] == identifiant)
    assert rappel["type"] == "rappel"
    assert rappel["pseudo"] == "thomas"
    # Les actions voyagent avec la notification : le bot n'a pas à connaître
    # la machine à états pour afficher ses boutons.
    assert "faite" in rappel["actions_possibles"]


def test_un_echec_d_envoi_laisse_la_notification_en_attente(client, thomas):
    client.post("/planning/placer", headers=thomas)
    forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)

    notification = client.get("/notifications", headers=thomas).json()[0]

    # R28 : un échec ne perd pas le message.
    echec = client.post(f"/notifications/{notification['id_notification']}/envoyee",
                        headers=thomas, json={"reussi": False, "motif": "Telegram muet"})
    assert echec.json()["statut"] == "echec"
    assert echec.json()["date_envoi"] is None

    reussite = client.post(f"/notifications/{notification['id_notification']}/envoyee",
                           headers=thomas, json={"reussi": True})
    assert reussite.json()["statut"] == "envoyee"
    assert reussite.json()["date_envoi"] is not None


def test_les_notifications_envoyees_quittent_la_file(client, thomas):
    client.post("/planning/placer", headers=thomas)
    forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)

    avant = client.get("/notifications", headers=thomas).json()
    for notification in avant:
        client.post(f"/notifications/{notification['id_notification']}/envoyee",
                    headers=thomas, json={"reussi": True})

    assert client.get("/notifications", headers=thomas).json() == []
    assert len(client.get("/notifications", headers=thomas, params={"toutes": True}).json()) \
        == len(avant)


# ---------------------------------------------------------------------------
# Report d'office
# ---------------------------------------------------------------------------

def test_une_tache_non_faite_revient_le_lendemain(client, thomas):
    client.post("/planning/placer", headers=thomas)
    identifiant = forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)

    # On simule la fin de journée en faisant passer le créneau dans le passé.
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute(
            """
            UPDATE occurrence
               SET creneau = tstzrange(debut_jour(jour_de(now()) - 1),
                                       debut_jour(jour_de(now())), '[)'),
                   fenetre = tstzrange(debut_jour(jour_de(now()) - 2),
                                       debut_jour(jour_de(now())), '[)')
             WHERE id_occurrence = %s
            """,
            (identifiant,),
        )

    reportees = client.post("/notifications/report", headers=thomas).json()["reportees"]
    assert reportees == 1

    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] == "a_placer"
    assert detail["nb_relances"] == 1
    # R26 : le compteur rend le retard visible, sans quoi une tâche repoussée
    # chaque soir paraîtrait éternellement à l'heure.
    assert detail["en_retard"] is True
    assert detail["jours_de_retard"] >= 1


def test_l_ordonnanceur_est_arrete_pendant_les_tests(client):
    # On déclenche les tâches à la main : dépendre de l'heure qu'il est rendrait
    # les tests instables.
    assert client.get("/sante").json()["ordonnanceur"] == []
