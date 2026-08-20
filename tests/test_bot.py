"""Ce que le bot sait faire, testé sans Telegram.

Toute la logique vit dans `conversation.py` précisément pour ça : vérifier
qu'un bouton « fait » valide la bonne occurrence ne doit pas demander de
parler à un service extérieur.
"""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg
import pytest

from api import conversation as conv
from tests.conftest import CLE_LORETTE, CLE_THOMAS, _url

PARIS = ZoneInfo("Europe/Paris")
TELEGRAM_THOMAS = 111222333


@pytest.fixture(autouse=True)
def sans_appairage():
    """Chaque test repart d'un bot qui ne connaît personne."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("UPDATE utilisateur SET id_telegram = NULL")
    yield


# ---------------------------------------------------------------------------
# Appairage
# ---------------------------------------------------------------------------

def test_la_cle_d_api_sert_de_mot_de_passe(base):
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    assert compte is not None
    assert compte["pseudo"] == "thomas"

    assert conv.compte_de(TELEGRAM_THOMAS)["pseudo"] == "thomas"


def test_une_cle_inconnue_n_appaire_rien(base):
    assert conv.appairer("X" * 48, TELEGRAM_THOMAS) is None
    assert conv.compte_de(TELEGRAM_THOMAS) is None


def test_un_inconnu_n_est_relie_a_aucun_compte(base):
    assert conv.compte_de(999999) is None


def test_on_peut_changer_de_telephone(base):
    conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    conv.appairer(CLE_THOMAS, 444555666)

    assert conv.compte_de(TELEGRAM_THOMAS) is None
    assert conv.compte_de(444555666)["pseudo"] == "thomas"


def test_delier_le_compte(base):
    conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    assert conv.desappairer(TELEGRAM_THOMAS) is True
    assert conv.compte_de(TELEGRAM_THOMAS) is None


def test_deux_comptes_deux_conversations(base):
    conv.appairer(CLE_THOMAS, 111)
    conv.appairer(CLE_LORETTE, 222)

    assert conv.compte_de(111)["pseudo"] == "thomas"
    assert conv.compte_de(222)["pseudo"] == "lorette"


# ---------------------------------------------------------------------------
# Heures de silence
# ---------------------------------------------------------------------------

def test_pas_de_notification_la_nuit():
    # Faire vibrer un téléphone à 3h du matin pour une poussière est le meilleur
    # moyen de faire couper les notifications.
    assert conv.en_silence(datetime(2026, 8, 20, 3, 0, tzinfo=PARIS))
    assert conv.en_silence(datetime(2026, 8, 20, 23, 45, tzinfo=PARIS))
    assert conv.en_silence(datetime(2026, 8, 20, 7, 0, tzinfo=PARIS))


def test_la_journee_n_est_pas_silencieuse():
    assert not conv.en_silence(datetime(2026, 8, 20, 7, 30, tzinfo=PARIS))
    assert not conv.en_silence(datetime(2026, 8, 20, 12, 0, tzinfo=PARIS))
    assert not conv.en_silence(datetime(2026, 8, 20, 21, 0, tzinfo=PARIS))
    assert not conv.en_silence(datetime(2026, 8, 20, 23, 29, tzinfo=PARIS))


def test_le_silence_se_termine_le_lendemain_matin():
    prochain = conv.prochain_rappel(1)
    assert prochain > datetime.now(PARIS)
    assert prochain.astimezone(PARIS).hour == 7


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

def occurrence_de(client, thomas, code: str) -> dict:
    toutes = client.get("/occurrences", headers=thomas).json()
    return next(o for o in toutes if o["tache_code"] == code)


def test_le_bouton_fait_valide_l_occurrence(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    aspirateur = occurrence_de(client, thomas, "ASPIRATEUR")
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)

    reponse = conv.executer_action("valider", aspirateur["id_occurrence"],
                                   compte["id_utilisateur"])
    assert "noté" in reponse

    apres = client.get(f"/occurrences/{aspirateur['id_occurrence']}", headers=thomas).json()
    assert apres["statut"] == "faite"


def test_le_bouton_plus_tard_repousse(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    aspirateur = occurrence_de(client, thomas, "ASPIRATEUR")
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)

    reponse = conv.executer_action("reporter", aspirateur["id_occurrence"],
                                   compte["id_utilisateur"])
    assert "demain" in reponse

    apres = client.get(f"/occurrences/{aspirateur['id_occurrence']}", headers=thomas).json()
    assert apres["statut"] == "a_placer"


def test_la_lessive_de_travail_refuse_d_etre_repoussee(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    lessive = occurrence_de(client, thomas, "LESSIVE_TRAVAIL")
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)

    reponse = conv.executer_action("reporter", lessive["id_occurrence"],
                                   compte["id_utilisateur"])
    assert "ne résoudrait rien" in reponse

    apres = client.get(f"/occurrences/{lessive['id_occurrence']}", headers=thomas).json()
    assert apres["statut"] != "a_placer"


def test_le_bouton_non_recree_la_tache_sans_assigne(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    aspirateur = occurrence_de(client, thomas, "ASPIRATEUR")
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)

    reponse = conv.executer_action("refuser", aspirateur["id_occurrence"],
                                   compte["id_utilisateur"])
    assert "sans assigné" in reponse

    apres = client.get(f"/occurrences/{aspirateur['id_occurrence']}", headers=thomas).json()
    assert apres["statut"] == "abandonnee"


def test_une_action_inconnue_est_refusee(base):
    with pytest.raises(ValueError):
        conv.executer_action("supprimer", 1, 1)


def test_valider_deux_fois_remonte_le_refus_de_la_base(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    aspirateur = occurrence_de(client, thomas, "ASPIRATEUR")
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)

    conv.executer_action("valider", aspirateur["id_occurrence"], compte["id_utilisateur"])

    with pytest.raises(psycopg.Error) as erreur:
        conv.executer_action("valider", aspirateur["id_occurrence"], compte["id_utilisateur"])
    # Le message de la base est déjà rédigé en français : le bot le montrera tel quel.
    assert "close" in erreur.value.diag.message_primary


# ---------------------------------------------------------------------------
# Mise en forme
# ---------------------------------------------------------------------------

def test_le_planning_du_jour_separe_horaires_et_rappels(client, thomas, base):
    debut = datetime.now(PARIS).replace(hour=14, minute=0, second=0, microsecond=0)
    client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": "Cours IDMC",
        "debut": debut.isoformat(), "fin": (debut + timedelta(hours=2)).isoformat(),
        "lieu": "Salle 104",
    })
    client.post("/planning/placer", headers=thomas)

    # Le moteur étale les tâches : rien ne garantit qu'un rappel tombe
    # aujourd'hui. On en force un, sinon le test dépendrait du calendrier.
    from tests.test_boucle_quotidienne import forcer_au_jour_meme
    forcer_au_jour_meme("ASPIRATEUR")

    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    texte = conv.planning_du_jour(compte["id_utilisateur"])

    assert "14h00–16h00  Cours IDMC — Salle 104" in texte
    # Les rappels sans heure sont listés à part, avec une puce.
    assert "○ Passer l'aspirateur" in texte


def test_un_planning_vide_le_dit(base):
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    assert conv.planning_du_jour(compte["id_utilisateur"], dans_jours=300) == "Rien de prévu."


def test_l_etat_du_stock_annonce_la_prochaine_lessive(client, thomas, base):
    for jour in range(1, 5):
        base_jour = datetime.now(PARIS) + timedelta(days=jour)
        client.post("/occupations", headers=thomas, json={
            "type": "travail", "libelle": "Shift",
            "debut": base_jour.replace(hour=17, minute=0, second=0, microsecond=0).isoformat(),
            "fin": base_jour.replace(hour=23, minute=0, second=0, microsecond=0).isoformat(),
        })
    client.post("/stock/TSHIRT/mouvement", headers=thomas,
                json={"type": "salissure", "quantite": 2})

    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    texte = conv.etat_du_stock(compte["id_utilisateur"])

    assert "T-shirt" in texte
    assert "Lessive avant" in texte or "trop tard" in texte


# ---------------------------------------------------------------------------
# File d'attente
# ---------------------------------------------------------------------------

def test_la_file_ignore_les_comptes_non_relies(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    client.post("/notifications/bilan", headers=thomas)

    # Personne n'est appairé : rien à envoyer.
    assert conv.notifications_a_envoyer() == []

    conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    en_attente = conv.notifications_a_envoyer()
    assert en_attente
    assert all(n["id_telegram"] == TELEGRAM_THOMAS for n in en_attente)


def test_un_echec_d_envoi_conserve_la_notification(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    client.post("/notifications/bilan", headers=thomas)
    conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)

    notification = conv.notifications_a_envoyer()[0]
    conv.marquer_envoyee(notification["id_notification"], reussi=False)

    restantes = [n["id_notification"] for n in conv.notifications_a_envoyer()]
    assert notification["id_notification"] not in restantes

    with psycopg.connect(_url()) as conn:
        statut = conn.execute(
            "SELECT statut FROM notification WHERE id_notification = %s",
            (notification["id_notification"],),
        ).fetchone()[0]
    assert statut == "echec"


def test_les_rappels_portent_leur_occurrence(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    from tests.test_boucle_quotidienne import forcer_au_jour_meme

    identifiant = forcer_au_jour_meme("ASPIRATEUR")
    client.post("/notifications/bilan", headers=thomas)
    client.post("/notifications/relance", headers=thomas)

    # Les deux comptes sont reliés : la répartition peut confier l'aspirateur
    # à l'un ou à l'autre, la file doit le porter dans les deux cas.
    conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    conv.appairer(CLE_LORETTE, TELEGRAM_THOMAS + 1)

    rappels = [n for n in conv.notifications_a_envoyer() if n["type"] == "rappel"]
    cible = next(n for n in rappels if n["id_occurrence"] == identifiant)
    # C'est ce qui permet d'accrocher les boutons au bon message.
    assert "faite" in cible["actions_possibles"]
