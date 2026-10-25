"""Bilan du matin, relance du soir, report d'office.

C'est la boucle qui décide si le système sert à quelque chose : sans elle, le
planning existe mais personne ne le regarde.
"""

from datetime import UTC, datetime, timedelta

import psycopg

from tests.conftest import _url


def notifications(pseudo: str | None = None) -> list[dict]:
    """Notifications, éventuellement filtrées sur leur destinataire.

    Le filtre est important : chaque utilisateur reçoit son propre bilan, et
    supposer lequel arrive en premier rendrait les tests fragiles.
    """
    filtre = "WHERE u.pseudo = %s" if pseudo else ""
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        return conn.execute(
            f"SELECT n.type, n.contenu, n.statut, n.id_occurrence, u.pseudo "
            f"  FROM notification n "
            f"  JOIN utilisateur u ON u.id_utilisateur = n.id_utilisateur "
            f"  {filtre} ORDER BY n.id_notification",
            (pseudo,) if pseudo else (),
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
                   statut  = 'planifiee',
                   -- Le moteur assigne toujours ce qu'il place. Laisser
                   -- l'assignation au hasard de la répartition rendait ces
                   -- tests dépendants du jour : une occurrence tombée à
                   -- Lorette, ou à personne, n'apparaît pas dans le bilan de
                   -- Thomas.
                   id_utilisateur = (SELECT id_utilisateur FROM utilisateur
                                      WHERE pseudo = 'thomas')
             WHERE o.id_occurrence = (
                   SELECT o2.id_occurrence FROM occurrence o2
                     JOIN tache t ON t.id_tache = o2.id_tache
                    WHERE t.id_tache = essais.tache_de(%s)
                      AND o2.statut IN ('a_placer', 'planifiee')
                    ORDER BY lower(o2.fenetre), o2.id_occurrence LIMIT 1)
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

    bilans = [n for n in notifications("thomas") if n["type"] == "bilan"]
    assert bilans
    assert "Passer l'aspirateur" in bilans[0]["contenu"]

    # PLA-5 : le créneau communiqué est figé, il ne bougera plus au replacement.
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

    bilans = [n for n in notifications("thomas") if n["type"] == "bilan"]
    assert bilans
    assert "Sans créneau" in bilans[0]["contenu"]


def test_le_bilan_previent_l_administrateur_des_pannes(client, thomas):
    # IDMC_ICS est active et n'a jamais été collectée : elle est en panne.
    client.post("/planning/placer", headers=thomas)
    forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)

    bilans = [n for n in notifications("thomas") if n["type"] == "bilan"]
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

    # Sans filtre sur le destinataire : la répartition peut confier
    # l'aspirateur à l'un ou à l'autre selon la charge de chacun.
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

    rappels = [n for n in notifications("thomas") if n["type"] == "rappel"]
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
    # Le destinataire est l'assigné du moment, qui dépend de la répartition.
    assert rappel["pseudo"] in ("thomas", "lorette")
    # Les actions voyagent avec la notification : le bot n'a pas à connaître
    # la machine à états pour afficher ses boutons.
    assert "faite" in rappel["actions_possibles"]


def test_un_echec_d_envoi_laisse_la_notification_en_attente(client, thomas):
    client.post("/planning/placer", headers=thomas)
    forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)

    notification = client.get("/notifications", headers=thomas).json()[0]

    # NOT-2 : un échec ne perd pas le message.
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

    bilan = client.post("/notifications/report", headers=thomas).json()
    assert bilan["reportees"] == 1
    assert bilan["abandonnees"] == 0

    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] == "a_placer"
    assert detail["nb_relances"] == 1
    # EXE-6 : le compteur rend le retard visible, sans quoi une tâche repoussée
    # chaque soir paraîtrait éternellement à l'heure.
    assert detail["en_retard"] is True
    assert detail["jours_de_retard"] >= 1


def test_l_ordonnanceur_est_arrete_pendant_les_tests(client):
    # On déclenche les tâches à la main : dépendre de l'heure qu'il est rendrait
    # les tests instables.
    assert client.get("/sante").json()["ordonnanceur"] == []


# ---------------------------------------------------------------------------
# Oubli des retards                                                    (EXE-12)
#
# Le report d'office repoussait sans fin. Une tâche non faite revenait chaque
# soir, un jour de retard de plus, et la liste ne se vidait jamais.
# ---------------------------------------------------------------------------

def _vieillir(identifiant: int, jours: int) -> None:
    """Fait passer une occurrence pour vieille de `jours` jours de retard."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute(
            """
            UPDATE occurrence
               SET creneau     = tstzrange(
                                     debut_jour(jour_de(now()) - 1) + INTERVAL '3 hours',
                                     debut_jour(jour_de(now()) - 1) + INTERVAL '4 hours', '[)'),
                   fenetre     = tstzrange(debut_jour(jour_de(now()) - %(j)s - 1),
                                           debut_jour(jour_de(now())), '[)'),
                   nb_relances = %(j)s
             WHERE id_occurrence = %(id)s
            """,
            {"id": identifiant, "j": jours},
        )


def _a_oublier(code_tache: str) -> None:
    """TAC-24 : « si pas faite : l'oublier », réglé comme dans le détail."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("UPDATE tache SET si_pas_faite = 'oublier' "
                     "WHERE id_tache = essais.tache_de(%s)", (code_tache,))


def test_une_tache_a_reporter_ne_s_abandonne_jamais(client, thomas):
    """TAC-24 : « la reporter », elle revient jusqu'à être faite, même après cinq jours."""
    client.post("/planning/placer", headers=thomas)
    identifiant = forcer_au_jour_meme("ASPIRATEUR")
    _vieillir(identifiant, 6)

    bilan = client.post("/notifications/report", headers=thomas).json()
    assert bilan["reportees"] >= 1

    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] == "a_placer"


def test_quatre_jours_de_retard_se_reportent_encore(client, thomas):
    # La borne compte : à quatre jours on reporte, à cinq on oublie. Sans ce
    # test, une inégalité stricte mal placée passerait inaperçue.
    client.post("/planning/placer", headers=thomas)
    identifiant = forcer_au_jour_meme("ASPIRATEUR")
    _vieillir(identifiant, 4)

    bilan = client.post("/notifications/report", headers=thomas).json()
    assert bilan["reportees"] >= 1

    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] == "a_placer"


def _seance_choisie(client, thomas) -> int:
    """Une séance choisie la semaine prochaine, à déplacer ensuite à la main."""
    from api import sport

    moi = client.get("/moi", headers=thomas).json()["id_utilisateur"]
    lundi = sport.lundi_de(sport.aujourd_hui()) + timedelta(days=7)
    salle = sport.lieu_par_nom("salle")["id_lieu"]
    return sport.choisir(moi, salle, datetime.combine(
        lundi + timedelta(days=1), datetime.min.time().replace(hour=18),
        tzinfo=sport._fuseau()))


def test_une_seance_de_sport_s_oublie_plus_vite(client, thomas):
    # Une séance manquée ne se rattrape pas, elle se remplace par la suivante.
    identifiant = _seance_choisie(client, thomas)
    _vieillir(identifiant, 3)

    bilan = client.post("/notifications/report", headers=thomas).json()
    assert bilan["abandonnees"] >= 1

    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] == "abandonnee"


def test_une_seance_de_sport_de_deux_jours_tient_encore(client, thomas):
    # À deux jours elle attend encore sa réponse : c'est à trois qu'on renonce.
    identifiant = _seance_choisie(client, thomas)
    _vieillir(identifiant, 2)

    client.post("/notifications/report", headers=thomas)
    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] != "abandonnee"


def test_l_oubli_previent_plutot_que_de_disparaitre(client, thomas):
    _a_oublier("ASPIRATEUR")
    client.post("/planning/placer", headers=thomas)
    identifiant = forcer_au_jour_meme("ASPIRATEUR")
    _vieillir(identifiant, 2)
    client.post("/notifications/report", headers=thomas)

    contenus = [n["contenu"] for n in
                client.get("/notifications", headers=thomas,
                           params={"toutes": True}).json()]
    assert any("oubliée" in c for c in contenus), contenus


def test_solder_les_retards_vide_l_ardoise(client, thomas):
    client.post("/planning/placer", headers=thomas)
    identifiant = forcer_au_jour_meme("ASPIRATEUR")
    _vieillir(identifiant, 2)

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        soldees = conn.execute("SELECT solder_les_retards() AS n").fetchone()["n"]
    assert soldees >= 1

    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] == "abandonnee"
    assert "soldée" in detail["motif"]


def test_solder_les_retards_ne_touche_pas_ce_qui_est_a_l_heure(client, thomas):
    client.post("/planning/placer", headers=thomas)
    a_venir = [o for o in client.get("/occurrences", headers=thomas).json()
               if o["statut"] in ("a_placer", "planifiee") and not o["en_retard"]]
    assert a_venir, "il faut des occurrences à l'heure pour que le test ait un sens"

    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("SELECT solder_les_retards()")

    apres = {o["id_occurrence"]: o["statut"]
             for o in client.get("/occurrences", headers=thomas).json()}
    for o in a_venir:
        assert apres[o["id_occurrence"]] != "abandonnee"


# ---------------------------------------------------------------------------
# Ce qui n'a jamais eu de créneau                              (EXE-12, PLA-11)
# ---------------------------------------------------------------------------

def _sans_creneau(code_tache: str, echeance_dans_jours: int) -> int:
    """Une occurrence à placer dont l'échéance tombe dans N jours."""
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row, autocommit=True) as conn:
        ligne = conn.execute(
            """
            UPDATE occurrence o
               SET creneau = NULL,
                   statut  = 'a_placer',
                   motif   = 'Aucune place de 15 min',
                   -- Le bilan lu est celui de Thomas. Sans cela, le test
                   -- dépendait de la répartition : il suffisait qu'une autre
                   -- tâche disparaisse pour que l'aspirateur passe à Lorette,
                   -- et les tests qui vérifient une absence passaient à vide.
                   id_utilisateur = (SELECT id_utilisateur FROM utilisateur
                                      WHERE pseudo = 'thomas'),
                   -- Une fenêtre d'un jour qui se referme à l'échéance voulue,
                   -- pour que la borne reste valide même dans le passé.
                   fenetre = tstzrange(debut_jour(jour_de(now()) + %(j)s - 1),
                                       debut_jour(jour_de(now()) + %(j)s), '[)')
             WHERE o.id_occurrence = (
                   SELECT o2.id_occurrence FROM occurrence o2
                     JOIN tache t ON t.id_tache = o2.id_tache
                    WHERE t.id_tache = essais.tache_de(%(c)s)
                      AND o2.statut IN ('a_placer', 'planifiee')
                    ORDER BY o2.id_occurrence LIMIT 1)
            RETURNING o.id_occurrence
            """,
            {"c": code_tache, "j": echeance_dans_jours},
        ).fetchone()
    assert ligne is not None
    return ligne["id_occurrence"]


def test_une_occurrence_jamais_placee_finit_par_etre_oubliee(client, thomas):
    # Le report ne regardait que les tâches posées. Une occurrence sans créneau
    # n'était donc jamais vue, jamais abandonnée, et s'empilait : sept lessives
    # de travail au même jour de retard, une douzaine de séances de sport.
    _a_oublier("ASPIRATEUR")
    client.post("/planning/placer", headers=thomas)
    identifiant = _sans_creneau("ASPIRATEUR", -6)   # échéance dépassée de 6 jours

    bilan = client.post("/notifications/report", headers=thomas).json()
    assert bilan["oubliees"] >= 1

    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] == "abandonnee"


def test_une_echeance_encore_a_venir_ne_s_oublie_pas(client, thomas):
    client.post("/planning/placer", headers=thomas)
    identifiant = _sans_creneau("ASPIRATEUR", 4)

    client.post("/notifications/report", headers=thomas)
    detail = client.get(f"/occurrences/{identifiant}", headers=thomas).json()
    assert detail["statut"] != "abandonnee"


def _bilan_du_matin(client, thomas) -> str:
    """Le bilan de Thomas. La liste rend ceux des deux comptes : prendre le
    dernier renvoyait celui de Lorette dès qu'elle avait quelque chose ce
    jour-là."""
    client.post("/notifications/bilan", headers=thomas)
    bilans = [n["contenu"] for n in
              client.get("/notifications", headers=thomas, params={"toutes": True}).json()
              if n["pseudo"] == "thomas"
              and ("Sans créneau" in n["contenu"] or "Aujourd'hui" in n["contenu"])]
    return bilans[-1] if bilans else ""


def test_le_bilan_montre_ce_qui_est_encore_rattrapable(client, thomas):
    # PLA-11 : entre deux jours et une semaine, on peut encore réorganiser.
    client.post("/planning/placer", headers=thomas)
    _sans_creneau("ASPIRATEUR", 4)

    assert "Sans créneau" in _bilan_du_matin(client, thomas)


def test_le_bilan_tait_une_echeance_deja_depassee(client, thomas):
    # C'était le gros du bruit : « Aucune place avant le 31/08 » un 14 septembre.
    client.post("/planning/placer", headers=thomas)
    _sans_creneau("ASPIRATEUR", -3)

    contenu = _bilan_du_matin(client, thomas)
    assert "Aucune place" not in contenu, contenu


def test_le_bilan_tait_une_echeance_trop_lointaine(client, thomas):
    # À trois semaines, ce n'est pas encore un problème.
    client.post("/planning/placer", headers=thomas)
    _sans_creneau("ASPIRATEUR", 21)

    contenu = _bilan_du_matin(client, thomas)
    assert "Aucune place" not in contenu, contenu


# ---------------------------------------------------------------------------
# Deux pannes vues sur le téléphone                             (EXE-13, NOT-4)
# ---------------------------------------------------------------------------

def test_valider_une_seance_notifiee_n_echoue_pas(client, thomas):
    # « update or delete on table "occurrence" violates foreign key constraint
    # "notification_id_occurrence_fkey". PLA-7 efface les prévisions de la
    # même tâche à la validation ; le sport en posait trois par semaine, chacune
    # notifiée le soir, et la suppression butait sur la notification. Depuis la
    # migration 033 les séances sont choisies, donc épinglées : le cas doit
    # rester sans effet, et la validation passer.
    from api import sport

    moi = client.get("/moi", headers=thomas).json()["id_utilisateur"]
    lundi = sport.lundi_de(sport.aujourd_hui()) + timedelta(days=7)
    course = sport.lieu_par_nom("course")["id_lieu"]
    seances = [{"id_occurrence": sport.choisir(moi, course, datetime.combine(
        lundi + timedelta(days=d), datetime.min.time().replace(hour=18),
        tzinfo=sport._fuseau()))} for d in (1, 3)]

    # Une relance pointe sur celle qu'on ne valide pas : c'est elle que la
    # validation de l'autre va effacer.
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute(
            "INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu) "
            "VALUES (1, %s, 'rappel', 'Séance de sport : c''est fait ?')",
            (seances[1]["id_occurrence"],))

    reponse = client.post(f"/occurrences/{seances[0]['id_occurrence']}/valider",
                          headers=thomas)
    assert reponse.status_code == 200, reponse.text


def test_la_notification_survit_a_l_occurrence_effacee(client, thomas):
    # Le message a été envoyé et lu : il fait partie de l'histoire. C'est le
    # lien qui se défait, pas la trace.
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("SELECT generer_occurrences(35)")

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        occurrence = conn.execute(
            "SELECT id_occurrence FROM occurrence "
            " WHERE statut IN ('a_placer', 'planifiee') ORDER BY id_occurrence LIMIT 1"
        ).fetchone()["id_occurrence"]

    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute(
            "INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu) "
            "VALUES (1, %s, 'rappel', 'Un message déjà lu')", (occurrence,))
        conn.execute("DELETE FROM occurrence WHERE id_occurrence = %s", (occurrence,))

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        ligne = conn.execute(
            "SELECT contenu, id_occurrence FROM notification "
            " WHERE contenu = 'Un message déjà lu'").fetchone()

    assert ligne is not None, "la notification a disparu avec l'occurrence"
    assert ligne["id_occurrence"] is None


def test_le_bilan_du_matin_montre_les_cours(client, thomas):
    # NOT-4 : le bilan ne lisait que les tâches. Une journée de cours n'y
    # apparaissait pas, alors qu'elle figurait dans /planning et sur le
    # téléphone.
    from datetime import datetime, time
    from zoneinfo import ZoneInfo

    paris = ZoneInfo("Europe/Paris")
    aujourd_hui = datetime.now(paris).date()
    debut = datetime.combine(aujourd_hui, time(10), paris)
    fin = datetime.combine(aujourd_hui, time(11, 30), paris)

    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute(
            "INSERT INTO occupation (id_utilisateur, id_source, type, libelle, "
            "                        periode, lieu) "
            "VALUES (1, (SELECT id_source FROM source WHERE code = 'MANUELLE'), "
            "        'cours', 'CM Conception de systèmes d''information', "
            "        tstzrange(%s, %s, '[)'), 'Salle 206/207')", (debut, fin))

    client.post("/notifications/bilan", headers=thomas)
    contenus = [n["contenu"] for n in
                client.get("/notifications", headers=thomas,
                           params={"toutes": True}).json()]

    bilan = next((c for c in contenus if "Aujourd'hui" in c), "")
    assert "CM Conception" in bilan, bilan
    assert "10h00" in bilan, bilan
    assert "Salle 206/207" in bilan, bilan
