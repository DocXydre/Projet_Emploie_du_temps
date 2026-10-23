"""Le HAL du foyer et l'aiguillage                          (HDF, AIG, lot 16)

Le même module d'appel sert les deux HAL. Un message de l'appli va au HAL du
foyer, au HAL sport, ou aux deux, selon l'onglet, les mots-clés, puis un petit
modèle. Le HAL du foyer a sa consigne, ses outils, sa mémoire commune, et les
conversations qu'on a avec lui restent à celui qui les a eues.
"""

import uuid

import psycopg
import pytest

from api import aiguillage
from api.coach import appel, modele
from tests.conftest import _url
from tests.test_coach import FauxModele, demande, dit, u  # noqa: F401 - fixture


def sql(requete: str, *params):
    with psycopg.connect(_url(), autocommit=True) as conn:
        cur = conn.execute(requete, params)
        return cur.fetchall() if cur.description else None


def un(requete: str, *params):
    lignes = sql(requete, *params)
    return lignes[0][0] if lignes else None


def _id(pseudo: str) -> int:
    return un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)


@pytest.fixture(autouse=True)
def sans_minuteur(monkeypatch):
    from api import demandes
    monkeypatch.setattr(demandes, "MINUTEUR_DES_GESTES", False)


@pytest.fixture
def joue(monkeypatch):
    monkeypatch.setattr(appel, "controle_du_plan", lambda u: [])

    def installer(*tours) -> FauxModele:
        faux = FauxModele(*tours)
        monkeypatch.setattr(modele, "appeler", faux)
        return faux
    return installer


@pytest.fixture
def sans_petit_modele(monkeypatch):
    """AIG-4 : le petit modèle ne doit pas être appelé ; s'il l'est, le test le dit."""
    appels = []
    monkeypatch.setattr(aiguillage, "par_modele",
                        lambda texte, u: appels.append(texte) or None)
    return appels


def ecrire(client, entetes, texte, ecran=None, hal=None, chemin="question"):
    corps = {"texte": texte, "cle_client": str(uuid.uuid4())}
    if ecran:
        corps["ecran"] = ecran
    if hal:
        corps["hal"] = hal
    reponse = client.post(f"/coach/{chemin}", headers=entetes, json=corps)
    assert reponse.status_code == 200, reponse.text
    return reponse.json()


# ---------------------------------------------------------------------------
# L'aiguillage, seul                                          (AIG-1 à AIG-4)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(("texte", "attendu"), [
    ("Décale l'aspirateur à jeudi", "maison"),
    ("Qui sort les poubelles ce soir ?", "maison"),
    ("Je pars chez mes parents vendredi", "maison"),
    ("Ma séance de muscu de demain, je peux la raccourcir ?", "sport"),
    ("J'ai mal au genou", "sport"),
    ("Combien de courses à pied cette semaine ?", "sport"),
    ("Je pars ce week-end, décale ma séance et la litière", "les_deux"),
    ("Bonjour", None),
])
def test_les_mots(texte, attendu):
    assert aiguillage.par_mots(texte) == attendu


def test_le_contexte_tranche_d_abord(monkeypatch):
    monkeypatch.setattr(aiguillage, "par_modele", lambda texte, u: None)
    # Une séance jointe : le sport, quoi qu'en disent les mots.
    assert aiguillage.choisir("et la litière ?", 1, "Maison", id_occurrence=4).hal == "sport"
    # L'onglet : sans mot de l'autre côté, il tranche.
    choix = aiguillage.choisir("Bonjour", 1, "Maison · Toutes les tâches")
    assert (choix.hal, choix.par) == ("maison", "contexte")
    assert aiguillage.choisir("Bonjour", 1, "Sport").hal == "sport"
    # Les mots de l'autre côté envoient aux deux.
    choix = aiguillage.choisir("décale ma séance et la litière", 1, "Maison")
    assert (choix.hal, choix.par) == ("les_deux", "mots")
    # Aujourd'hui ne tranche pas : les mots, puis le petit modèle, puis personne.
    assert aiguillage.choisir("la vaisselle", 1, "Aujourd'hui").hal == "maison"
    choix = aiguillage.choisir("Bonjour", 1, "Aujourd'hui")
    assert (choix.hal, choix.par) == (None, "utilisateur")


def test_le_petit_modele_et_sa_reponse():
    assert aiguillage.lire_le_mot("Maison.") == "maison"
    assert aiguillage.lire_le_mot("les deux") == "les_deux"
    assert aiguillage.lire_le_mot("Sport") == "sport"
    assert aiguillage.lire_le_mot("Je ne sais pas") is None
    assert aiguillage.lire_le_mot("aucun") is None


# ---------------------------------------------------------------------------
# Le HAL du foyer                                              (HDF, lot 16)
# ---------------------------------------------------------------------------

def test_depuis_maison_le_hal_du_foyer_repond(client, thomas, joue, sans_petit_modele):
    faux = joue(demande(("lire_taches", {})), dit("L'aspirateur est prévu jeudi déjà."))
    rendu = ecrire(client, thomas, "Décale l'aspirateur à jeudi", ecran="Maison")

    assert rendu["hal"] == "foyer"
    assert rendu["message"] == "L'aspirateur est prévu jeudi déjà."
    assert sans_petit_modele == []
    # Sa consigne, pas le dossier sportif ; ses outils, pas ceux des séances.
    premier = faux.appels[0]
    assert premier["systeme"][0]["text"].startswith("# HAL du foyer")
    assert "La mémoire du foyer" in premier["systeme"][1]["text"]
    assert {"lire_taches", "reporter_tache", "ajouter_memoire_foyer"} <= set(premier["outils"])
    assert not {"proposer_seances", "demander_report", "valider_semaine",
                "noter_mesure"} & set(premier["outils"])

    appel_ = sql("SELECT hal, moment, id_foyer IS NOT NULL FROM appel_coach")
    assert appel_ == [("foyer", "maison", True)]
    assert sql("SELECT auteur, hal, aiguillage FROM echange ORDER BY id_echange") == [
        ("utilisateur", "foyer", "contexte"), ("coach", "foyer", None)]


def test_le_hal_du_foyer_sans_hal_sport(client, lorette, joue):
    """HDF-1 : Lorette n'a pas démarré son HAL sport ; la maison lui répond."""
    joue(dit("Tu as la vaisselle ce soir."))
    rendu = ecrire(client, lorette, "Qu'est-ce que j'ai à faire ce soir ?",
                   ecran="Aujourd'hui")
    assert rendu["hal"] == "foyer"


def _aspirateur(client, thomas) -> int:
    requete = """SELECT o.id_occurrence FROM occurrence o JOIN tache t USING (id_tache)
                   WHERE t.code = 'ASPIRATEUR' AND o.statut IN ('a_placer', 'planifiee')
                   ORDER BY upper(o.fenetre) LIMIT 1"""
    if un(requete) is None:
        client.post("/planning/placer", headers=thomas)
    return un(requete)


def test_un_geste_du_hal_du_foyer(client, thomas, lorette, joue, monkeypatch):
    """ACT-2 : fait sans bouton d'accord, quelques secondes après la réponse."""
    from api import demandes
    monkeypatch.setattr(demandes, "DELAI_GESTE_SECONDES", 0)
    occurrence = _aspirateur(client, thomas)
    joue(demande(("reporter_tache", {"id_occurrence": occurrence,
                                     "motif": "Thomas le demande"})),
         dit("C'est reporté."))
    rendu = ecrire(client, thomas, "Reporte l'aspirateur", ecran="Maison")

    element = next(e for e in rendu["elements"] if e["type"] == "demande")
    assert element["geste"] is True
    assert [a["libelle"] for a in element["actions"]] == ["Annuler"]
    # Pas dans les demandes en attente, et pas de notification d'accord.
    assert not client.get("/demandes?en_attente=true", headers=thomas).json()
    assert un("SELECT count(*) FROM notification WHERE type = 'demande'") == 0

    assert demandes.executer_les_gestes() == 1
    assert un("SELECT etat FROM demande") == "acceptee"
    assert un("SELECT nb_relances FROM occurrence WHERE id_occurrence = %s", occurrence) >= 0
    # NOT-17 : la raison dit qui l'a demandé à HAL.
    origine = un("SELECT origine FROM evenement WHERE objet = 'occurrence' "
                 "ORDER BY id_evenement DESC LIMIT 1")
    assert origine.startswith("demandé à HAL par thomas"), origine


def test_annuler_un_geste(client, thomas, joue, monkeypatch):
    """ACT-2 : « Annuler » dans les cinq secondes refuse le geste ; rien ne change."""
    from api import demandes
    monkeypatch.setattr(demandes, "DELAI_GESTE_SECONDES", 0)
    occurrence = _aspirateur(client, thomas)
    avant = sql("SELECT fenetre, statut FROM occurrence WHERE id_occurrence = %s", occurrence)
    joue(demande(("reporter_tache", {"id_occurrence": occurrence, "motif": "demandé"})),
         dit("C'est reporté."))
    rendu = ecrire(client, thomas, "Reporte l'aspirateur", ecran="Maison")
    annuler = next(e for e in rendu["elements"] if e["type"] == "demande")["actions"][0]
    assert client.post(annuler["route"], headers=thomas).status_code == 200

    assert demandes.executer_les_gestes() == 0
    assert un("SELECT etat FROM demande") == "refusee"
    assert sql("SELECT fenetre, statut FROM occurrence WHERE id_occurrence = %s",
               occurrence) == avant


def test_un_geste_refuse_par_la_base(client, thomas, joue):
    """ACT-1 : les mêmes refus que le bouton ; le modèle lit le motif, rien n'est déposé."""
    faux = joue(demande(("arreter_tache", {"id_tache": 999999, "motif": "demandé"})),
                dit("Je ne trouve pas cette tâche."))
    ecrire(client, thomas, "Arrête la tâche des vitres", ecran="Maison")
    resultat = faux.resultats()[0]
    assert resultat["is_error"]
    assert un("SELECT count(*) FROM demande") == 0


def test_la_memoire_du_foyer(client, thomas, lorette, joue):
    joue(demande(("ajouter_memoire_foyer", {"ligne": "Sassy vomit si la litière attend"})),
         dit("C'est noté pour le foyer."))
    ecrire(client, thomas, "Retiens que Sassy vomit si la litière attend", ecran="Maison")

    # HDF-4 : commune, Lorette la lit, et la corrige en son nom.
    lue = client.get("/hal-foyer/memoire", headers=lorette).json()
    assert "Sassy vomit" in lue["semaine"]["texte"]
    corrigee = client.put("/hal-foyer/memoire", headers=lorette, json={
        "niveau": "globale", "texte": "Sassy : changer la litière tôt."}).json()
    assert corrigee["globale"]["texte"] == "Sassy : changer la litière tôt."
    assert corrigee["globale"]["nom_auteur"] == "Lorette"

    # Trop longue : refusée avec son motif.
    trop = client.put("/hal-foyer/memoire", headers=thomas,
                      json={"niveau": "semaine", "texte": "x" * 3001})
    assert trop.status_code == 422


def test_les_conversations_restent_a_leur_auteur(client, thomas, lorette, joue):
    """HDF-5 : Lorette ne lit pas la conversation de Thomas avec le HAL du foyer."""
    joue(dit("D'accord."))
    ecrire(client, thomas, "Je déteste passer l'aspirateur", ecran="Maison")
    assert client.get("/hal-foyer/echanges", headers=thomas).json()
    assert client.get("/hal-foyer/echanges", headers=lorette).json() == []
    assert client.get("/coach/echanges", headers=lorette).json() == []


def test_les_deux_hal_et_une_reponse(client, thomas, joue, u):  # noqa: F811
    """AIG-5 : depuis Maison, « ma séance et la litière » part aux deux."""
    faux = joue(dit("Pour la maison : la litière passe à dimanche."),
                dit("Pour le sport : ta séance passe à mardi."))
    rendu = ecrire(client, thomas, "Je pars ce week-end, décale ma séance et la litière",
                   ecran="Maison")

    assert rendu["hal"] == "les_deux"
    assert {p["hal"] for p in rendu["parties"]} == {"foyer", "sport"}
    assert "la litière" in rendu["message"] and "ta séance" in rendu["message"]
    # Le texte n'est gardé qu'une fois ; chaque HAL le relit.
    assert sql("SELECT hal FROM echange WHERE auteur = 'utilisateur'") == [("les_deux",)]
    assert sorted(h for (h,) in sql("SELECT hal FROM appel_coach")) == ["foyer", "sport"]
    for appel_ in faux.appels:
        assert "décale ma séance et la litière" in appel_["messages"][0]["content"][0]["text"]
        assert "ne traite que ta part" in appel_["messages"][0]["content"][0]["text"]


def test_un_appel_en_cours_par_hal(client, thomas, joue, u):  # noqa: F811
    """HDF-7 : un appel sport en cours n'empêche pas de parler au HAL du foyer."""
    sql("INSERT INTO appel_coach (id_utilisateur, moment, declencheur, operation, modele) "
        "VALUES (%s, 'chat', 'utilisateur', 'op-bloque', 'm')", u)
    joue(dit("Oui."))
    rendu = ecrire(client, thomas, "La vaisselle est faite ?", ecran="Maison")
    assert rendu["auteur"] == "coach"
    with pytest.raises(psycopg.errors.UniqueViolation):
        sql("INSERT INTO appel_coach (id_utilisateur, moment, declencheur, operation, modele) "
            "VALUES (%s, 'chat', 'utilisateur', 'op-deux', 'm')", u)


def test_sans_aiguillage_on_demande(client, thomas, monkeypatch, joue, u):  # noqa: F811
    """AIG-4 : rien ne tranche ; l'appli demande, puis renvoie avec le choix."""
    monkeypatch.setattr(aiguillage, "par_modele", lambda texte, u: None)
    rendu = ecrire(client, thomas, "Bonjour", ecran="Aujourd'hui")
    assert rendu["message"] == "C'est pour la maison ou pour le sport ?"
    assert rendu["aiguiller"] == {"texte": "Bonjour"}
    assert un("SELECT count(*) FROM appel_coach") == 0

    joue(dit("Bonjour Thomas."))
    rendu = ecrire(client, thomas, "Bonjour", ecran="Aujourd'hui", hal="maison")
    assert rendu["hal"] == "foyer"
    assert un("SELECT aiguillage FROM echange WHERE auteur = 'utilisateur'") == "utilisateur"


def test_le_hal_du_foyer_arrete(client, thomas, lorette, joue):
    """HDF-1 : arrêté par l'administrateur, la maison n'a plus de HAL. Lorette, sans
    HAL sport, n'a plus personne à qui parler."""
    reglage = client.patch("/foyer", headers=thomas, json={"hal_actif": False})
    assert reglage.status_code == 200 and reglage.json()["hal_actif"] is False
    assert client.patch("/foyer", headers=lorette, json={"hal_actif": True}).status_code == 403
    reponse = client.post("/coach/question", headers=lorette, json={
        "texte": "La vaisselle ?", "cle_client": str(uuid.uuid4()), "ecran": "Maison"})
    assert reponse.status_code == 403
    assert reponse.json()["code"] == "coach_inactif"


def test_les_gestes_du_hal_sport(client, thomas, joue, u):  # noqa: F811
    """ACT-1 : dans le chat, le HAL sport a les gestes de l'onglet Sport, pas ceux de
    la maison ni les demandes."""
    faux = joue(dit("D'accord."))
    ecrire(client, thomas, "Valide ma semaine", ecran="Sport")
    outils_ = set(faux.appels[0]["outils"])
    assert {"valider_semaine", "valider_seance", "declarer_seance_pas_faite",
            "deplacer_ou_supprimer_seance"} <= outils_
    assert not {"demander_tache", "creer_tache", "reporter_tache"} & outils_
