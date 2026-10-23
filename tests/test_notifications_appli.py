"""Les notifications de l'appli : heures de chacun, Apple, changements, orbe (lot 3)."""

import base64
import json
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import httpx
import psycopg
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from api import apple, changements, operation
from api.config import configuration
from api.ordonnanceur import placer, servir
from tests.conftest import _url

PARIS = ZoneInfo("Europe/Paris")
JETON = "ab" * 32


def sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row, autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def un(requete: str, *parametres):
    lignes = sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def _id(pseudo: str) -> int:
    return un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)


def paris(jour: int, heure: int, minute: int = 0) -> datetime:
    return datetime(2026, 10, jour, heure, minute, tzinfo=PARIS)


def minuit(dans_jours: int) -> datetime:
    return (datetime.now(PARIS) + timedelta(days=dans_jours)).replace(
        hour=0, minute=0, second=0, microsecond=0)


def _silence_ailleurs() -> None:
    """Un silence de cinq minutes, douze heures plus loin : les tests tournent à toute heure."""
    loin = datetime.now(PARIS) + timedelta(hours=12)
    debut = loin.replace(minute=loin.minute - loin.minute % 5, second=0, microsecond=0)
    sql("UPDATE utilisateur SET silence_debut = %s, silence_fin = %s",
        debut.time(), (debut + timedelta(minutes=5)).time())


# ---------------------------------------------------------------------------
# Les heures de chacun                                                 NOT-15
# ---------------------------------------------------------------------------

def test_les_heures_par_defaut(client, thomas):
    assert client.get("/moi/heures", headers=thomas).json() == {
        "bilan": "07:00", "relance": "21:00", "recap": "23:00",
        "silence_debut": "23:30", "silence_fin": "07:30"}


def test_chacun_regle_ses_heures(client, thomas, lorette):
    reponse = client.patch("/moi/heures", headers=lorette, json={"bilan": "08:30"})
    assert reponse.status_code == 200, reponse.text
    assert reponse.json()["bilan"] == "08:30"
    assert client.get("/moi/heures", headers=thomas).json()["bilan"] == "07:00"


@pytest.mark.parametrize("reglage, mot", [
    ({"bilan": "07:03"}, "cinq en cinq"),
    ({"recap": "16:00"}, "18h"),
    ({"bilan": "06:00"}, "silence"),
    ({"silence_debut": "07:30"}, "même heure"),
])
def test_une_heure_impossible_est_refusee(client, thomas, reglage, mot):
    reponse = client.patch("/moi/heures", headers=thomas, json=reglage)
    assert reponse.status_code == 409
    assert mot in reponse.json()["message"]
    assert client.get("/moi/heures", headers=thomas).json()["bilan"] == "07:00"


def test_les_rendez_vous_dus_a_l_heure_de_chacun(client):
    sql("UPDATE utilisateur SET heure_bilan = '08:00' WHERE pseudo = 'lorette'")
    thomas, lorette = _id("thomas"), _id("lorette")

    def dus(instant):
        return {(d["id_utilisateur"], d["moment"])
                for d in sql("SELECT * FROM rendez_vous_dus(%s)", instant)}

    assert (thomas, "bilan") not in dus(paris(14, 6, 55))
    assert (thomas, "bilan") in dus(paris(14, 7, 0))
    assert (lorette, "bilan") not in dus(paris(14, 7, 5))
    assert (lorette, "bilan") in dus(paris(14, 8, 5))
    # Trois heures après, c'est trop tard : le bilan de la journée ne part plus.
    assert (thomas, "bilan") not in dus(paris(14, 10, 1))
    # Le récap de 23h vaut encore à 1h du matin.
    assert (thomas, "recap") in dus(paris(15, 1, 0))


def test_un_rendez_vous_ne_se_sert_qu_une_fois(client):
    thomas = _id("thomas")
    jour = datetime.now(PARIS).date()
    assert servir(thomas, "relance", jour) is True
    assert servir(thomas, "relance", jour) is False
    assert un("SELECT count(*) FROM passage WHERE id_utilisateur = %s", thomas) == 1


def test_une_heure_deja_passee_vaut_des_le_lendemain(client, thomas):
    maintenant = datetime.now(PARIS)
    if maintenant.hour < 1 or maintenant.hour >= 23:
        pytest.skip("trop près de minuit pour choisir une heure passée et une à venir")
    sql("UPDATE utilisateur SET silence_debut = '23:55', silence_fin = '00:00'")
    passee = (maintenant - timedelta(minutes=30)).replace(second=0, microsecond=0)
    passee = passee.replace(minute=passee.minute - passee.minute % 5)

    client.patch("/moi/heures", headers=thomas, json={"relance": passee.strftime("%H:%M")})
    servis = sql("SELECT moment, jour FROM passage WHERE id_utilisateur = %s", _id("thomas"))
    assert servis == [{"moment": "relance", "jour": maintenant.date()}]


def test_le_silence_est_celui_de_chacun(client):
    sql("UPDATE utilisateur SET silence_debut = '22:00', silence_fin = '06:00' "
        "WHERE pseudo = 'lorette'")
    thomas, lorette = _id("thomas"), _id("lorette")
    assert un("SELECT en_silence(%s, %s)", lorette, paris(14, 22, 30)) is True
    assert un("SELECT en_silence(%s, %s)", thomas, paris(14, 22, 30)) is False
    assert un("SELECT en_silence(%s, %s)", thomas, paris(14, 7, 0)) is True
    assert un("SELECT en_silence(%s, %s)", lorette, paris(14, 7, 0)) is False


# ---------------------------------------------------------------------------
# L'envoi par Apple                                                    NOT-16
# ---------------------------------------------------------------------------

@pytest.fixture
def cle_apple():
    """Une clé ES256 de test, posée dans la configuration le temps du test."""
    privee = ec.generate_private_key(ec.SECP256R1())
    pem = privee.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                               serialization.NoEncryption())
    conf = configuration()
    avant = (conf.apns_cle, conf.apns_id_cle, conf.apns_equipe)
    conf.apns_cle = base64.b64encode(pem).decode()
    conf.apns_id_cle, conf.apns_equipe = "CLE1234567", "EQUIPE1234"
    apple.oublier_le_jeton()
    yield privee.public_key()
    conf.apns_cle, conf.apns_id_cle, conf.apns_equipe = avant
    apple.oublier_le_jeton()


def _client(reponses: list[httpx.Response], recues: list[httpx.Request]) -> httpx.Client:
    def repondre(requete: httpx.Request) -> httpx.Response:
        recues.append(requete)
        return reponses.pop(0) if reponses else httpx.Response(200)
    return httpx.Client(transport=httpx.MockTransport(repondre))


def _appareil(client, entetes, environnement="production"):
    assert client.post("/moi/appareils", headers=entetes,
                       json={"jeton": JETON, "environnement": environnement}).status_code == 200


def _notifier(pseudo="thomas", type_="bilan", contenu="Aujourd'hui :\n• 9h00 Cours"):
    return un("INSERT INTO notification (id_utilisateur, type, contenu) "
              "VALUES (%s, %s, %s) RETURNING id_notification", _id(pseudo), type_, contenu)


def _statut(id_notification):
    return un("SELECT apple_statut FROM notification WHERE id_notification = %s", id_notification)


def test_une_notification_part_vers_l_iphone(client, thomas, cle_apple):
    _silence_ailleurs()
    _appareil(client, thomas, "developpement")
    n = _notifier()
    recues: list[httpx.Request] = []

    bilan = apple.envoyer_la_file(_client([], recues))

    assert bilan["envoyees"] == 1
    assert _statut(n) == "envoyee"
    (requete,) = recues
    assert str(requete.url) == f"https://api.sandbox.push.apple.com/3/device/{JETON}"
    assert requete.headers["apns-topic"] == "fr.docxydre.hal"
    assert requete.headers["apns-push-type"] == "alert"
    charge = json.loads(requete.content)
    assert charge["aps"]["alert"] == {"title": "Ta journée",
                                      "body": "Aujourd'hui :\n• 9h00 Cours"}
    assert charge["hal"]["lien"] == {"ecran": "aujourdhui"}

    # Le jeton du fournisseur est signé par la clé du compte développeur.
    entete, corps, signature = requete.headers["authorization"].removeprefix("bearer ").split(".")
    brute = base64.urlsafe_b64decode(signature + "==")
    der = encode_dss_signature(int.from_bytes(brute[:32], "big"), int.from_bytes(brute[32:], "big"))
    cle_apple.verify(der, f"{entete}.{corps}".encode(), ec.ECDSA(hashes.SHA256()))
    assert json.loads(base64.urlsafe_b64decode(entete + "=="))["kid"] == "CLE1234567"
    assert json.loads(base64.urlsafe_b64decode(corps + "=="))["iss"] == "EQUIPE1234"


def test_sans_iphone_rien_n_attend(client, cle_apple):
    n = _notifier()
    apple.envoyer_la_file(_client([], []))
    assert _statut(n) == "sans_appareil"


def test_un_iphone_qui_n_a_plus_l_appli_est_oublie(client, thomas, cle_apple):
    _silence_ailleurs()
    _appareil(client, thomas)
    n = _notifier()
    apple.envoyer_la_file(_client([httpx.Response(410, json={"reason": "Unregistered"})], []))
    assert _statut(n) == "sans_appareil"
    assert un("SELECT count(*) FROM appareil") == 0


def test_un_echec_passager_garde_la_notification(client, thomas, cle_apple):
    _silence_ailleurs()
    _appareil(client, thomas)
    n = _notifier()
    apple.envoyer_la_file(_client([httpx.Response(503)], []))
    assert _statut(n) == "a_envoyer"
    assert un("SELECT apple_essais FROM notification WHERE id_notification = %s", n) == 1
    apple.envoyer_la_file(_client([], []))
    assert _statut(n) == "envoyee"


def test_un_jeton_refuse_est_refait(client, thomas, cle_apple):
    _silence_ailleurs()
    _appareil(client, thomas)
    n = _notifier()
    recues: list[httpx.Request] = []
    apple.envoyer_la_file(_client(
        [httpx.Response(403, json={"reason": "ExpiredProviderToken"})], recues))
    assert _statut(n) == "envoyee"
    assert len(recues) == 2


def test_rien_ne_part_pendant_le_silence(client, thomas, cle_apple):
    maintenant = datetime.now(PARIS)
    sql("UPDATE utilisateur SET silence_debut = %s, silence_fin = %s",
        (maintenant - timedelta(hours=1)).time().replace(second=0, microsecond=0),
        (maintenant + timedelta(hours=1)).time().replace(second=0, microsecond=0))
    _appareil(client, thomas)
    n = _notifier()
    recues: list[httpx.Request] = []
    apple.envoyer_la_file(_client([], recues))
    assert recues == []
    assert _statut(n) == "a_envoyer"


def test_sans_cle_rien_ne_part_et_rien_ne_se_perd(client, thomas):
    _silence_ailleurs()
    _appareil(client, thomas)
    n = _notifier()
    assert apple.envoyer_la_file(_client([], []))["desactive"] is True
    assert _statut(n) == "a_envoyer"
    # Un jour plus tard, elle est périmée : la clé arrivée, elle ne tombera pas.
    sql("UPDATE notification SET date_creation = now() - INTERVAL '25 hours'")
    apple.envoyer_la_file(_client([], []))
    assert _statut(n) == "perimee"


def test_le_lien_ouvre_le_bon_ecran():
    base = {"type": "rappel", "contenu": "x", "id_notification": 1}
    assert apple.lien({**base, "id_occurrence": 4, "tache_code": "ASPI"}) == {
        "ecran": "tache", "id": 4}
    assert apple.lien({**base, "id_occurrence": 4, "tache_code": "SPORT"}) == {
        "ecran": "seance", "id": 4}
    assert apple.lien({**base, "type": "coach"}) == {"ecran": "hal"}
    assert apple.lien({**base, "type": "changement", "operation": "op"}) == {
        "ecran": "historique", "operation": "op"}
    assert apple.lien({**base, "type": "sport"}) == {"ecran": "semaine"}


def test_le_texte_perd_ses_balises_et_se_coupe():
    long = "<b>Gras</b> **fort** " + "a" * 3000
    corps = apple.charge({"type": "coach", "contenu": long, "id_notification": 1})
    texte = corps["aps"]["alert"]["body"]
    assert texte.startswith("Gras fort ")
    assert len(texte) == apple.MAX_CORPS


# ---------------------------------------------------------------------------
# Les changements avec leur raison                                     NOT-17
# ---------------------------------------------------------------------------

def _vieillir_le_journal():
    sql("UPDATE evenement SET quand = quand - INTERVAL '1 minute'")


@pytest.fixture
def place(client, thomas):
    client.post("/planning/placer", headers=thomas)
    sql("UPDATE curseur SET dernier = (SELECT COALESCE(max(id_evenement), 0) FROM evenement)")


def test_une_tache_faite_par_l_autre_s_annonce_avec_son_nom(client, thomas, place):
    occurrence = un(
        """SELECT o.id_occurrence FROM occurrence o JOIN tache t USING (id_tache)
            WHERE o.id_utilisateur = %s AND o.statut IN ('planifiee', 'notifiee')
              AND t.categorie <> 'sport'
            ORDER BY lower(o.creneau) LIMIT 1""", _id("lorette"))
    if occurrence is None:
        pytest.skip("aucune tâche placée pour Lorette")
    assert client.post(f"/occurrences/{occurrence}/valider",
                       headers=thomas).status_code == 200
    _vieillir_le_journal()

    assert changements.annoncer() >= 1
    annonces = sql("SELECT id_utilisateur, contenu, id_occurrence FROM notification "
                   "WHERE type = 'changement'")
    assert {a["id_utilisateur"] for a in annonces} == {_id("lorette")}
    assert "faite par Thomas" in annonces[0]["contenu"]


def test_un_changement_part_avec_sa_raison_en_une_seule_notification(client, lorette, place):
    a_elle = un("""SELECT count(*) FROM occurrence o JOIN tache t USING (id_tache)
                    WHERE o.id_utilisateur = %s AND o.statut IN ('planifiee', 'notifiee')
                      AND t.categorie <> 'sport' AND lower(o.creneau) < %s""",
                _id("lorette"), minuit(5))
    if not a_elle:
        pytest.skip("aucune tâche de Lorette dans les jours qui viennent")
    client.post("/absences", headers=lorette, json={
        "debut": minuit(0).isoformat(), "fin": minuit(5).isoformat(), "lieu": "Lusse"})
    # Le placement qui suit est une autre action, celle de l'ordonnanceur : la
    # raison se retrouve quand même.
    with operation.ouvrir("Placement du matin", acteur="ordonnanceur"):
        placer()
    _vieillir_le_journal()

    changements.annoncer()
    annonces = sql("SELECT id_utilisateur, contenu, operation FROM notification "
                   "WHERE type = 'changement' ORDER BY id_notification")
    pour_elle = [a for a in annonces if a["id_utilisateur"] == _id("lorette")]
    assert len(pour_elle) == 1
    assert "Pourquoi : absence de Lorette" in pour_elle[0]["contenu"]
    # Une notification par personne et par action.
    assert len({(a["id_utilisateur"], a["operation"]) for a in annonces}) == len(annonces)


def test_le_journal_ne_se_raconte_qu_une_fois(client, thomas, place):
    client.post("/absences", headers=thomas, json={
        "debut": minuit(0).isoformat(), "fin": minuit(5).isoformat(), "lieu": "Lusse"})
    _vieillir_le_journal()
    premiere = changements.annoncer()
    assert changements.annoncer() == 0
    assert un("SELECT count(*) FROM notification WHERE type = 'changement'") == premiere


def test_le_bot_ne_porte_pas_les_changements(client):
    from api import conversation as conv
    sql("UPDATE utilisateur SET id_telegram = 42 WHERE pseudo = 'thomas'")
    _notifier(type_="changement", contenu="Aspirateur : déplacée")
    assert conv.notifications_a_envoyer() == []


# ---------------------------------------------------------------------------
# Le « ! » de l'orbe                                                   NOT-18
# ---------------------------------------------------------------------------

def test_hal_met_un_point_d_exclamation_jusqu_a_ce_qu_on_ouvre(client, thomas, lorette):
    assert client.get("/moi/orbe", headers=thomas).json()["a_dire"] is False
    _notifier(type_="coach", contenu="Le récap de ce soir")
    assert client.get("/moi/orbe", headers=thomas).json()["a_dire"] is True
    assert client.get("/moi/orbe", headers=lorette).json()["a_dire"] is False

    vu = client.post("/moi/orbe/vu", headers=thomas).json()
    assert vu["a_dire"] is False
    assert vu["messages"] == 0
