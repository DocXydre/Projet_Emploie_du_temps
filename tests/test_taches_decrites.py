"""Les tâches sans réglage à part, et leur description               (lot 18)

Aucune tâche n'a de réglage que le formulaire ne montre pas (TAC-29) : ce qui
faisait les tâches d'origine est dans leur description, que HAL applique (MTA,
VER). Une tâche arrêtée se reprend ou s'efface (TAC-30, TAC-31), les types de
base restent (TAC-25, TAC-26), et « Si pas faite » vaut pour toutes (TAC-24).
"""

from datetime import time, timedelta

import psycopg
import pytest

from api.coach import foyer as hal_foyer
from api.coach import verification
from api.ordonnanceur import placer, report_de_minuit
from tests.test_ensemble import OUVERTS, _id, minuit, sql, un


def _tache(libelle: str) -> int:
    return un("SELECT id_tache FROM tache WHERE libelle = %s", libelle)


def _nouvelle(libelle: str = "Nettoyer la hotte", **reglages) -> int:
    reglages.setdefault("p_tous_les_jours", 14 if not reglages.get("p_selon_description") else None)
    noms = ", ".join(f"{k} => %({k})s" for k in reglages)
    with psycopg.connect(_url_de_test(), autocommit=True) as conn:
        return conn.execute(
            f"SELECT creer_tache(p_libelle => %(l)s, p_acteur => %(a)s, {noms})",
            {"l": libelle, "a": _id("thomas"), **reglages}).fetchone()[0]


def _url_de_test() -> str:
    from tests.conftest import _url
    return _url()


def _decrire(id_tache: int, texte: str) -> None:
    sql("SELECT ecrire_description_tache(%s, %s, %s)", id_tache, texte, _id("thomas"))


def _en_attente() -> list[dict]:
    return sql("SELECT id_occurrence, id_tache, raison FROM verification_tache "
               "WHERE traitee_le IS NULL ORDER BY id_verification")


# ---------------------------------------------------------------------------
# TAC-29 : plus aucun réglage à part
# ---------------------------------------------------------------------------

def test_la_tache_n_a_plus_de_colonne_cachee(base):
    colonnes = {c for (c,) in [tuple(x.values()) for x in sql(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'tache'")]}
    for retiree in ("code", "categorie", "utilise_machine", "requiert_les_deux", "reportable",
                    "abandon_apres_jours", "avant_depart", "au_retour_apres_jours",
                    "quota_hebdomadaire"):
        assert retiree not in colonnes
    assert {"revient", "arretee_le", "si_pas_faite"} <= colonnes


@pytest.mark.parametrize("libelle, extrait", [
    ("Sortir les poubelles", "avant que le dernier parte"),
    ("Sortir les poubelles", "veille au soir"),
    ("Lessive de blanc", "Une seule machine par jour"),
    ("Grand nettoyage à deux", "Se fait à deux"),
    ("Récurer", "bloc « Nettoyage »"),
    ("Sassy : changer l'eau", "à refaire au retour"),
])
def test_ce_qu_avaient_les_taches_d_origine_est_dans_leur_description(base, libelle, extrait):
    texte = un("SELECT texte FROM v_description_tache WHERE id_tache = %s", _tache(libelle))
    assert extrait in texte


def test_le_bloc_nettoyage_n_est_plus_un_lien(base):
    assert un("""SELECT count(*) FROM accompagnement a
                  WHERE a.id_tache = %s AND a.id_tache_jointe = %s""",
              _tache("Récurer"), _tache("Faire la poussière")) == 0
    # Les liens que le formulaire sait poser restent : l'aspirateur avec le récurage.
    assert un("""SELECT count(*) FROM accompagnement a
                  WHERE a.id_tache = %s AND a.id_tache_jointe = %s""",
              _tache("Récurer"), _tache("Passer l'aspirateur")) == 1


def test_le_pliage_ne_revient_plus_d_office_a_lorette(base):
    pliage = _tache("Plier et ranger le linge")
    sql("UPDATE tache SET id_utilisateur_defaut = %s WHERE id_tache = %s", _id("thomas"), pliage)
    try:
        sql("SELECT appliquer_assignations()")
        assert un("SELECT id_utilisateur_defaut FROM tache WHERE id_tache = %s",
                  pliage) == _id("thomas")
    finally:
        sql("UPDATE tache SET id_utilisateur_defaut = NULL WHERE id_tache = %s", pliage)


def test_la_tache_du_sport_est_la_seule_sans_type(base):
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("UPDATE tache SET id_type_tache = NULL WHERE id_tache = %s", _tache("Récurer"))


# ---------------------------------------------------------------------------
# TAC-30, TAC-31 : arrêter, reprendre, effacer
# ---------------------------------------------------------------------------

def test_une_tache_d_origine_s_arrete_et_se_reprend(client, thomas):
    poubelles = _tache("Sortir les poubelles")
    arretee = client.delete(f"/taches/{poubelles}", headers=thomas).json()
    assert arretee["active"] is False and arretee["arretee_le"] is not None
    assert un(f"SELECT count(*) FROM occurrence WHERE id_tache = %s AND statut IN {OUVERTS}",
              poubelles) == 0

    listees = client.get("/taches?seulement_actives=false", headers=thomas).json()
    assert any(t["id_tache"] == poubelles and not t["active"] for t in listees)

    reprise = client.post(f"/taches/{poubelles}/reprendre", headers=thomas).json()
    assert reprise["active"] is True and reprise["arretee_le"] is None
    # Régulière : due dès aujourd'hui, comme une tâche neuve ; sa description revient avec elle.
    assert un(f"""SELECT min(lower(fenetre)) FROM occurrence
                   WHERE id_tache = %s AND statut IN {OUVERTS}""", poubelles) < minuit(1)
    assert "veille au soir" in reprise["description"]["texte"]


def test_seule_une_tache_arretee_s_efface(client, thomas):
    hotte = _nouvelle()
    refus = client.delete(f"/taches/{hotte}/definitivement", headers=thomas)
    assert refus.status_code >= 400

    placer()
    # Un message déjà envoyé : arrêter la tâche ne retire que ceux qui attendent.
    sql("INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu, statut, "
        "date_envoi) SELECT %s, id_occurrence, 'alerte', 'lue', 'envoyee', now() "
        "FROM occurrence WHERE id_tache = %s", _id("thomas"), hotte)
    client.delete(f"/taches/{hotte}", headers=thomas)
    efface = client.delete(f"/taches/{hotte}/definitivement", headers=thomas).json()

    assert efface == {"efface": True, "libelle": "Nettoyer la hotte"}
    assert un("SELECT count(*) FROM tache WHERE id_tache = %s", hotte) == 0
    assert un("SELECT count(*) FROM occurrence WHERE id_tache = %s", hotte) == 0
    # EXE-13 : le message envoyé reste ; il perd seulement son lien.
    assert un("SELECT count(*) FROM notification WHERE contenu = 'lue' "
              "AND id_occurrence IS NULL") >= 1
    # Le journal garde l'effacement, avec le nom de la tâche.
    assert un("SELECT count(*) FROM evenement WHERE objet = 'tache' AND id_objet = %s "
              "AND apres IS NULL AND libelle = 'Nettoyer la hotte'", hotte) == 1


def test_une_tache_ponctuelle_passee_ne_se_reprend_pas(base):
    colis = _nouvelle("Rendre le colis", p_tous_les_jours=None, p_au=minuit(0).date())
    sql("SELECT arreter_tache(%s)", colis)
    sql("UPDATE occurrence SET fenetre = tstzrange(%s, %s, '[)') WHERE id_tache = %s",
        minuit(-3), minuit(-2), colis)
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("SELECT reprendre_tache(%s)", colis)


# ---------------------------------------------------------------------------
# TAC-25, TAC-26 : les types de base
# ---------------------------------------------------------------------------

def test_un_type_de_base_ne_se_supprime_pas_mais_se_renomme(client, thomas):
    chat = un("SELECT id_type_tache FROM type_tache WHERE base = 'animal'")
    sql("UPDATE tache SET id_type_tache = (SELECT id_type_tache FROM type_tache "
        "WHERE base = 'menage') WHERE id_type_tache = %s", chat)
    try:
        assert client.delete(f"/types-taches/{chat}", headers=thomas).status_code >= 400
        renomme = client.patch(f"/types-taches/{chat}", headers=thomas,
                               json={"libelle": "Sassy"}).json()
        assert renomme["libelle"] == "Sassy" and renomme["de_base"] is True
    finally:
        sql("UPDATE type_tache SET libelle = 'Chat' WHERE id_type_tache = %s", chat)
        sql("""UPDATE tache SET id_type_tache = %s
                WHERE libelle IN ('Litière : ramassage', 'Litière : vidage complet',
                                  'Sassy : changer l''eau', 'Sassy : laver la fontaine')""", chat)


def test_supprimer_un_type_du_foyer_range_ses_taches_arretees_dans_menage(base):
    plantes = un("SELECT enregistrer_type_tache(NULL, 'Plantes', '#22AA44', 'leaf', 5, 3)")
    ficus = _nouvelle("Arroser le ficus", p_type=plantes)
    sql("SELECT arreter_tache(%s)", ficus)

    sql("SELECT supprimer_type_tache(%s)", plantes)

    assert un("SELECT y.base FROM tache t JOIN type_tache y USING (id_type_tache) "
              "WHERE t.id_tache = %s", ficus) == "menage"


# ---------------------------------------------------------------------------
# TAC-24 : « Si pas faite », pour toutes
# ---------------------------------------------------------------------------

def _en_retard_de(id_tache: int, jours: int) -> None:
    sql("""UPDATE occurrence SET fenetre = tstzrange(%s, %s, '[)'), statut = 'planifiee',
                                 creneau = tstzrange(%s, %s, '[)')
            WHERE id_tache = %s AND statut IN ('a_placer', 'planifiee')""",
        minuit(-jours), minuit(-jours + 1), minuit(-jours), minuit(-jours + 1), id_tache)


def test_une_tache_reguliere_a_oublier_s_oublie(base):
    hotte = _nouvelle(p_si_pas_faite="oublier")
    sql("DELETE FROM occurrence WHERE id_tache = %s", hotte)
    sql("INSERT INTO occurrence (id_tache, fenetre, origine) "
        "VALUES (%s, tstzrange(%s, %s, '[)'), 'recurrence')", hotte, minuit(-2), minuit(-1))
    _en_retard_de(hotte, 2)

    report_de_minuit()

    assert {x["statut"] for x in sql("SELECT statut FROM occurrence WHERE id_tache = %s",
                                     hotte)} == {"abandonnee"}


def test_une_tache_reguliere_a_reporter_ne_s_abandonne_jamais(base):
    hotte = _nouvelle()
    sql("DELETE FROM occurrence WHERE id_tache = %s", hotte)
    sql("INSERT INTO occurrence (id_tache, fenetre, origine) "
        "VALUES (%s, tstzrange(%s, %s, '[)'), 'recurrence')", hotte, minuit(-9), minuit(-8))
    _en_retard_de(hotte, 9)

    report_de_minuit()

    assert "abandonnee" not in {x["statut"] for x in sql(
        "SELECT statut FROM occurrence WHERE id_tache = %s", hotte)}


def test_si_pas_faite_se_change_dans_le_detail(client, thomas):
    hotte = _nouvelle()
    lue = client.patch(f"/taches/{hotte}", headers=thomas, json={"si_pas_faite": "oublier"}).json()
    assert lue["si_pas_faite"] == "oublier"


# ---------------------------------------------------------------------------
# MTA-8, VER-1, VER-10 : ce que HAL pose selon une description
# ---------------------------------------------------------------------------

def test_une_tache_selon_sa_description_n_est_posee_que_par_hal(base):
    hotte = _nouvelle(p_selon_description=True)
    _decrire(hotte, "Les 19 et 23 du mois, un mois sur deux.")
    placer()
    assert un("SELECT count(*) FROM occurrence WHERE id_tache = %s", hotte) == 0

    jour = (minuit(3)).date()
    pose = un("SELECT placer_par_hal(NULL, %s, %s, NULL, %s, 'le 23 : un mois sur deux')",
              hotte, jour, _id("thomas"))
    placer()

    ligne = sql("SELECT origine, epinglee_par, statut, jour_de(lower(creneau)) AS jour "
                "FROM occurrence WHERE id_occurrence = %s", pose)[0]
    assert ligne == {"origine": "hal", "epinglee_par": "hal", "statut": "planifiee", "jour": jour}
    # VER-6 : la personne est prévenue, avec la raison.
    assert un("SELECT contenu FROM notification WHERE id_occurrence = %s",
              pose) == "Nettoyer la hotte : le 23 : un mois sur deux"


def test_hal_ne_deplace_pas_ce_qui_est_place_a_la_main(base):
    hotte = _nouvelle()
    placer()
    numero = un(f"SELECT id_occurrence FROM occurrence WHERE id_tache = %s AND statut IN {OUVERTS} "
                "ORDER BY lower(fenetre) LIMIT 1", hotte)
    sql("UPDATE occurrence SET epinglee = TRUE WHERE id_occurrence = %s", numero)
    assert un("SELECT epinglee_par FROM occurrence WHERE id_occurrence = %s", numero) == "admin"

    with pytest.raises(psycopg.errors.CheckViolation) as refus:
        sql("SELECT placer_par_hal(%s, NULL, %s, NULL, NULL, 'plus tard')",
            numero, minuit(5).date())
    assert "à la main" in str(refus.value)


def test_hal_ne_pose_pas_un_jour_d_absence(base):
    from tests.test_ensemble import absent
    hotte = _nouvelle()
    absent("thomas", minuit(4), minuit(6))
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("SELECT placer_par_hal(NULL, %s, %s, NULL, %s, 'avant de partir')",
            hotte, minuit(4).date(), _id("thomas"))


def test_hal_respecte_la_plage_d_une_tache_a_heure(base):
    poubelles = _tache("Sortir les poubelles")
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("SELECT placer_par_hal(NULL, %s, %s, %s, %s, 'avant le départ')",
            poubelles, minuit(2).date(), time(9, 0), _id("lorette"))
    pose = un("SELECT placer_par_hal(NULL, %s, %s, %s, %s, 'avant le départ')",
              poubelles, minuit(2).date(), time(20, 0), _id("lorette"))
    assert un("SELECT origine FROM occurrence WHERE id_occurrence = %s", pose) == "hal"


def test_hal_retire_une_prevision_mais_pas_ce_qui_est_annonce(base):
    hotte = _nouvelle()
    placer()
    numero = un(f"SELECT id_occurrence FROM occurrence WHERE id_tache = %s AND statut IN {OUVERTS} "
                "ORDER BY lower(fenetre) LIMIT 1", hotte)
    sql("UPDATE occurrence SET statut = 'notifiee' WHERE id_occurrence = %s", numero)
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("SELECT retirer_par_hal(%s, 'jamais le mardi')", numero)
    sql("UPDATE occurrence SET statut = 'planifiee' WHERE id_occurrence = %s", numero)
    sql("SELECT retirer_par_hal(%s, 'jamais le mardi')", numero)
    assert un("SELECT count(*) FROM occurrence WHERE id_occurrence = %s", numero) == 0


def test_hal_epingle_ce_qui_tombe_un_jour_d_absence_redevient_au_moteur(base):
    from tests.test_ensemble import absent
    hotte = _nouvelle()
    pose = un("SELECT placer_par_hal(NULL, %s, %s, NULL, %s, 'samedi')",
              hotte, minuit(3).date(), _id("thomas"))
    absent("thomas", minuit(3), minuit(4))

    placer()

    ligne = sql("SELECT epinglee, id_utilisateur, jour_de(lower(creneau)) AS jour "
                "FROM occurrence WHERE id_occurrence = %s", pose)[0]
    assert ligne["epinglee"] is False
    assert ligne["jour"] != minuit(3).date() or ligne["id_utilisateur"] != _id("thomas")


# ---------------------------------------------------------------------------
# VER-3 : la file des vérifications
# ---------------------------------------------------------------------------

def test_sans_description_rien_n_entre_dans_la_file(base):
    _nouvelle()
    placer()
    from tests.test_ensemble import absent
    absent("lorette", minuit(2), minuit(3))
    assert all(ligne["id_tache"] != _tache("Nettoyer la hotte") for ligne in _en_attente())


def test_un_cours_sur_le_jour_d_une_tache_decrite_la_fait_relire(base):
    hotte = _nouvelle()
    _decrire(hotte, "Un jour où Thomas est complètement libre.")
    pose = un("SELECT placer_par_hal(NULL, %s, %s, NULL, %s, 'ta seule journée vide')",
              hotte, minuit(5).date(), _id("thomas"))
    # Ce que HAL vient de faire n'y entre pas.
    assert all(ligne["id_occurrence"] != pose for ligne in _en_attente())

    sql("INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode) "
        "SELECT %s, id_source, 'cours', 'Cours ajouté', tstzrange(%s, %s, '[)') "
        "  FROM source ORDER BY id_source LIMIT 1",
        _id("thomas"), minuit(5).replace(hour=10), minuit(5).replace(hour=12))

    assert {"id_occurrence": pose, "id_tache": None, "raison": "occupation"} in _en_attente()


def test_une_absence_fait_relire_chaque_tache_decrite(base):
    from tests.test_ensemble import absent
    absent("thomas", minuit(4), minuit(6))
    taches = {ligne["id_tache"] for ligne in _en_attente() if ligne["raison"] == "absence"}
    assert _tache("Sortir les poubelles") in taches
    assert _tache("Passer l'aspirateur") not in taches


def test_le_placement_signale_ce_qu_il_cree_d_une_tache_decrite(base):
    hotte = _nouvelle()
    _decrire(hotte, "Jamais le mardi.")
    placer()
    assert any(ligne["raison"] == "creee" for ligne in _en_attente()
               if ligne["id_occurrence"] in {x["id_occurrence"] for x in sql(
                   "SELECT id_occurrence FROM occurrence WHERE id_tache = %s", hotte)})


# ---------------------------------------------------------------------------
# VER-4, VER-5 : les appels de HAL
# ---------------------------------------------------------------------------

@pytest.fixture
def appels(monkeypatch):
    faits: list[tuple[int, str, str]] = []

    def faux(id_admin: int, moment: str, precision: str) -> bool:
        faits.append((id_admin, moment, precision))
        return True

    monkeypatch.setattr(verification, "_appeler", faux)
    return faits


def test_une_file_vide_ne_fait_aucun_appel(base, appels):
    sql("DELETE FROM verification_tache")
    assert verification.verifier_la_file() == {"relues": 0}
    assert appels == []


def test_la_file_part_en_un_seul_appel_et_se_vide(base, appels):
    from tests.test_ensemble import absent
    absent("thomas", minuit(4), minuit(6))
    attendues = len(_en_attente())
    assert attendues > 1

    assert verification.verifier_la_file() == {"relues": attendues}
    assert len(appels) == 1 and appels[0][1] == "verification"
    assert "Sortir les poubelles" in appels[0][2]
    assert _en_attente() == []


def test_un_echec_garde_la_file(base, monkeypatch):
    from tests.test_ensemble import absent
    absent("thomas", minuit(4), minuit(6))
    monkeypatch.setattr(verification, "_appeler", lambda *a: False)
    verification.verifier_la_file()
    assert _en_attente() != []


def test_la_semaine_passe_une_fois_a_son_heure(base, appels):
    from api.coach.clair import maintenant
    lundi = maintenant().replace(hour=6, minute=0) - timedelta(days=maintenant().isoweekday() - 1)
    foyer = {"verification_jour": 1, "verification_heure": time(6, 30), "semaine_relue_le": None}
    assert not verification.semaine_due(foyer, lundi)
    assert verification.semaine_due(foyer, lundi.replace(hour=7))
    assert not verification.semaine_due({**foyer, "semaine_relue_le": lundi.date()},
                                        lundi.replace(hour=7))

    verification.verifier_la_semaine(lundi.replace(hour=7))
    assert [a[1] for a in appels] == ["semaine"]
    verification.verifier_la_semaine(lundi.replace(hour=8))
    assert [a[1] for a in appels] == ["semaine"]


# ---------------------------------------------------------------------------
# MTA-2 : HAL écrit la description ; l'appli la lit
# ---------------------------------------------------------------------------

def test_hal_ecrit_la_description_que_l_appli_montre(client, thomas):
    hotte = _nouvelle()
    rendu = hal_foyer.ecrire_description_tache(_id("thomas"), {
        "id_tache": hotte, "texte": "Les 19 et 23 du mois, un mois sur deux."})
    assert rendu["fait"] == "description écrite"

    lue = next(t for t in client.get("/taches", headers=thomas).json() if t["id_tache"] == hotte)
    assert lue["description"]["texte"] == "Les 19 et 23 du mois, un mois sur deux."
    assert lue["description"]["dite_par"] == "Thomas"


def test_le_widget_chat_suit_les_taches_du_type_chat(client, thomas):
    chat = un("SELECT id_type_tache FROM type_tache WHERE base = 'animal'")
    _nouvelle("Brosser Sassy", p_type=chat)
    placer()
    soins = client.get("/appli/aujourdhui", headers=thomas).json()["chat"]
    assert "Brosser Sassy" in {s["libelle"] for s in soins}


def test_c_est_fait_se_dit_par_le_numero_de_la_tache(client, thomas):
    hotte = _nouvelle()
    faite = client.post("/occurrences/faite", headers=thomas, json={"id_tache": hotte}).json()
    assert faite["statut"] == "faite" and faite["id_tache"] == hotte


def test_le_geste_de_creation_porte_la_description(base):
    """MTA-2 : une tâche que HAL crée n'existe qu'une fois le geste fait ; sa
    description part avec lui, et la tâche entre dans la file (VER-3)."""
    from api import demandes
    qui = demandes._appelant(_id("thomas"))
    creee = demandes._faire_tache(qui, demandes.PTache(
        libelle="Trier les papiers", selon_description=True,
        description="Les 19 et 23 du mois, un mois sur deux."), essai=False)

    assert un("SELECT texte FROM v_description_tache WHERE id_tache = %s",
              creee["id_tache"]) == "Les 19 et 23 du mois, un mois sur deux."
    assert {"id_occurrence": None, "id_tache": creee["id_tache"],
            "raison": "description"} in _en_attente()
