"""Lecture des confirmations d'achat SNCF.

Aucun de ces tests n'ouvre de connexion IMAP : les courriels sont fabriqués et
rejoués, comme les flux iCalendar et les réponses de la SNCF le sont ailleurs.

Deux choses comptent plus que le reste ici. Qu'un courriel usurpant l'identité
de la SNCF ne déclare rien — ils sont assez répandus pour que la question se
pose. Et qu'un courriel légitime qu'on n'a pas su lire soit conservé avec son
motif : le format ne nous appartient pas, il changera, et ce sera le seul
indice disponible le jour où plus rien n'arrive.
"""

import base64
import email.policy
from datetime import datetime, timedelta
from email.message import EmailMessage
from email.utils import format_datetime
from zoneinfo import ZoneInfo

import psycopg
import pytest

from api import billets
from api.collecteurs import courriel as lecteur
from tests.conftest import _url

PARIS = ZoneInfo("Europe/Paris")


# ---------------------------------------------------------------------------
# Fabrication de courriels
# ---------------------------------------------------------------------------

def _courriel(corps: str, *, de: str = "confirmation@mail.sncf-connect.com",
              sujet: str = "Confirmation de votre commande",
              identifiant: str = "<abc123@mail.sncf-connect.com>",
              html: bool = False) -> bytes:
    message = EmailMessage()
    message["From"] = f"SNCF Connect <{de}>"
    message["To"] = "thomas@example.org"
    message["Subject"] = sujet
    message["Message-ID"] = identifiant
    message["Date"] = format_datetime(datetime.now(PARIS))

    # HTML seul, et non en alternative : c'est le cas qu'on veut éprouver.
    # Avec une version texte à côté, le lecteur prendrait celle-là — ce qui
    # est le bon comportement, mais ne teste rien.
    message.set_content(corps, subtype="html" if html else "plain")
    return message.as_bytes()


def _un_jour(dans_jours: int) -> datetime:
    return (datetime.now(PARIS) + timedelta(days=dans_jours)).replace(
        hour=0, minute=0, second=0, microsecond=0)


MOIS_FR = ("janvier", "février", "mars", "avril", "mai", "juin", "juillet",
           "août", "septembre", "octobre", "novembre", "décembre")


def _date_fr(jour: datetime) -> str:
    return f"{jour.day} {MOIS_FR[jour.month - 1]} {jour.year}"


def _billet(aller: datetime, retour: datetime | None = None,
            reference: str = "RGTPLS") -> str:
    """Un récapitulatif dans la forme d'une confirmation d'achat."""
    texte = f"""Bonjour Thomas,

Votre commande est confirmée.
Référence de votre dossier voyage : {reference}

ALLER — {_date_fr(aller)}
Nancy Ville {aller:%Hh%M} → Saint-Dié-des-Vosges {aller + timedelta(minutes=95):%Hh%M}
Durée 1h35 — TER
"""
    if retour is not None:
        texte += f"""
RETOUR — {_date_fr(retour)}
Saint-Dié-des-Vosges {retour:%Hh%M} → Nancy Ville {retour + timedelta(minutes=95):%Hh%M}
Durée 1h35 — TER
"""
    texte += "\nBon voyage,\nL'équipe SNCF Connect\n"
    return texte


# ---------------------------------------------------------------------------
# Expéditeurs
# ---------------------------------------------------------------------------

def test_les_domaines_officiels_sont_acceptes(base):
    for adresse in ("no-reply@mail.sncf-connect.com", "x@mail.sncfconnect.com",
                    "y@info.sncf.com", "z@connect.sncf"):
        assert lecteur.expediteur_reconnu(adresse), adresse


def test_un_faux_courriel_sncf_ne_declare_rien(client, thomas):
    # Les mails frauduleux au nom de la SNCF sont assez courants pour que la
    # liste blanche soit une protection et non une formalité.
    depart = _un_jour(4).replace(hour=18, minute=12)
    faux = _courriel(_billet(depart, _un_jour(6).replace(hour=17)),
                     de="no-reply@sncf.fr")

    bilan = billets.relever(1, [faux])

    assert bilan["traites"] == 0
    assert bilan["ignores"] == 1
    assert client.get("/absences", headers=thomas).json() == []


def test_un_domaine_qui_ressemble_est_refuse(base):
    # « sncf-connect.com.attaquant.net » se termine bien par un domaine
    # légitime, sans en être un.
    assert not lecteur.expediteur_reconnu("a@mail.sncf-connect.com.attaquant.net")
    assert not lecteur.expediteur_reconnu("a@fake-sncf-connect.com")


# ---------------------------------------------------------------------------
# Accès à la boîte
# ---------------------------------------------------------------------------

def test_un_libelle_gmail_avec_espace_est_entre_guillemets(base):
    # Un libellé Gmail est un dossier IMAP, et s'appelle volontiers
    # « Billets SNCF ». Sans guillemets, l'espace coupe la commande en deux.
    assert lecteur.nom_de_dossier("Billets SNCF") == '"Billets SNCF"'
    assert lecteur.nom_de_dossier("INBOX") == '"INBOX"'
    assert lecteur.nom_de_dossier('"déjà cité"') == '"déjà cité"'


def test_la_recherche_filtre_par_date_et_expediteur(base):
    quand = datetime(2026, 8, 22, tzinfo=PARIS)

    assert lecteur.criteres_recherche(quand, "sncf") == (
        "SINCE", "22-Aug-2026", "FROM", "sncf")
    # Sans filtre, on ne demande que la date : un dossier dédié n'a pas
    # besoin qu'on trie côté serveur.
    assert lecteur.criteres_recherche(quand) == ("SINCE", "22-Aug-2026")


def test_l_identifiant_se_lit_dans_un_entete_seul(base):
    # C'est ce qui permet de ne rapatrier que les courriels neufs : un
    # en-tête pèse quelques centaines d'octets, un courriel avec ses images
    # cent fois plus.
    entete = b"Message-ID: <abc@mail.sncf-connect.com>\r\nSubject: x\r\n"
    assert lecteur.identifiant_de(entete) == "<abc@mail.sncf-connect.com>"

    # Les serveurs n'écrivent pas tous l'en-tête de la même façon.
    assert lecteur.identifiant_de(b"message-id: <b@x>\r\n") == "<b@x>"
    assert lecteur.identifiant_de(b"Subject: sans identifiant\r\n") == ""


def test_le_filtre_serveur_ne_remplace_pas_la_liste_blanche(base):
    # Un serveur qui filtrerait mal ne doit pas pouvoir faire entrer un
    # courriel non vérifié : c'est le lecteur qui tranche, pas la recherche.
    faux = _courriel(_billet(_un_jour(4).replace(hour=18, minute=12)),
                     de="contact@sncf-arnaque.fr")
    assert lecteur.analyser(faux).statut == "ignore"


# ---------------------------------------------------------------------------
# Lecture du billet
# ---------------------------------------------------------------------------

def test_un_aller_retour_se_lit(base):
    depart = _un_jour(4).replace(hour=18, minute=12)
    retour = _un_jour(6).replace(hour=17, minute=30)

    lu = lecteur.analyser(_courriel(_billet(depart, retour)))

    assert lu.statut == "traite"
    assert lu.reference == "RGTPLS"
    assert [s.sens for s in lu.segments] == ["aller", "retour"]
    assert lu.segments[0].depart == depart
    assert lu.segments[0].arrivee == depart + timedelta(minutes=95)
    assert lu.segments[1].depart == retour


def test_la_duree_du_trajet_n_est_pas_un_horaire(base):
    # « Durée 1h35 » figure entre les deux trajets. Prise pour un horaire,
    # elle décalerait tout l'appariement.
    depart = _un_jour(4).replace(hour=18, minute=12)
    lu = lecteur.analyser(_courriel(_billet(depart, _un_jour(6).replace(hour=17))))

    assert len(lu.segments) == 2
    assert all(s.arrivee - s.depart == timedelta(minutes=95) for s in lu.segments)


def test_un_aller_simple_se_lit(base):
    depart = _un_jour(4).replace(hour=18, minute=12)
    lu = lecteur.analyser(_courriel(_billet(depart)))

    assert lu.statut == "traite"
    assert len(lu.segments) == 1
    assert lu.segments[0].sens == "aller"


def test_le_meme_billet_en_html_se_lit_pareil(base):
    depart = _un_jour(4).replace(hour=18, minute=12)
    retour = _un_jour(6).replace(hour=17, minute=30)

    texte = lecteur.analyser(_courriel(_billet(depart, retour)))
    balise = "<p>" + _billet(depart, retour).replace("\n", "<br>") + "</p>"
    en_html = lecteur.analyser(_courriel(f"<html><body>{balise}</body></html>",
                                         html=True))

    # Le même voyage écrit sur une ligne ou sur quatre doit donner le même
    # résultat : d'où l'analyse par flux de jetons plutôt que ligne à ligne.
    assert [(s.depart, s.arrivee) for s in en_html.segments] \
        == [(s.depart, s.arrivee) for s in texte.segments]


def test_un_train_de_nuit_arrive_le_lendemain(base):
    depart = _un_jour(4).replace(hour=23, minute=10)
    corps = (f"Référence dossier voyage : ABCDEF\n"
             f"ALLER — {_date_fr(depart)}\n"
             f"Nancy Ville 23h10 → Saint-Dié-des-Vosges 00h45\n")

    lu = lecteur.analyser(_courriel(corps))
    assert lu.segments[0].arrivee - lu.segments[0].depart == timedelta(minutes=95)
    assert lu.segments[0].arrivee.day != lu.segments[0].depart.day


def test_une_gare_inconnue_rend_le_courriel_illisible(base):
    depart = _un_jour(4)
    corps = (f"Votre billet est confirmé.\n"
             f"ALLER — {_date_fr(depart)}\n"
             f"Nancy Ville 18h12 → Strasbourg 19h47\n")

    lu = lecteur.analyser(_courriel(corps))
    # Deviner serait pire : on préfère signaler.
    assert lu.statut == "illisible"
    assert "Aucun trajet reconnu" in lu.motif


def test_une_lettre_d_information_est_ignoree_sans_bruit(base):
    lu = lecteur.analyser(_courriel(
        "Découvrez nos offres de l'été.\nDes réductions toute l'année.",
        sujet="Nos meilleures offres"))

    # Légitime, mais sans billet : ce n'est pas un problème à signaler.
    assert lu.statut == "ignore"
    assert "sans trajet" in lu.motif


def test_un_abonnement_est_ignore_et_non_signale(base):
    # Cas réel : « Confirmation de votre commande » pour un abonnement TER.
    # Aucune gare nulle part, donc aucun trajet — et rien à corriger. Le
    # signaler éternellement comme illisible serait du bruit.
    lu = lecteur.analyser(_courriel(
        "Votre commande est confirmée.\n"
        "Référence de votre dossier : ABCDEF\n"
        "effectuee le 4 aout 2026, 15:50:07\n"
        "Montant : 29,00 €\n",
        sujet="Confirmation de votre commande"))

    assert lu.statut == "ignore"
    assert "abonnement" in lu.motif


def test_une_gare_reconnue_sans_trajet_reste_signalee(base):
    # Là, en revanche, il y a matière à corriger : le lecteur a vu une gare
    # qu'il connaît mais n'a pas su en tirer de trajet.
    lu = lecteur.analyser(_courriel(
        f"Votre billet\nDépart de Nancy Ville\n{_date_fr(_un_jour(3))}\n"
        f"Arrivée à Colmar 19h47\n"))

    assert lu.statut == "illisible"
    assert "NANCY" in lu.motif


def test_un_courriel_sans_expediteur_ne_fait_pas_planter(base):
    lu = lecteur.analyser(b"Subject: rien\r\n\r\ncorps")
    assert lu.statut == "ignore"


def test_les_orthographes_de_saint_die_sont_reconnues(base):
    for graphie in ("Saint-Dié-des-Vosges", "ST DIE DES VOSGES", "Saint Dié"):
        depart = _un_jour(4)
        corps = (f"billet — {_date_fr(depart)}\n"
                 f"Nancy 18h12 → {graphie} 19h47\n")
        lu = lecteur.analyser(_courriel(corps))
        assert lu.segments and lu.segments[0].arrivee_gare == "SAINT_DIE", graphie


# ---------------------------------------------------------------------------
# Le trajet lu dans le sujet
# ---------------------------------------------------------------------------

def _sujet_voyage(depart: str, arrivee: str, jour) -> str:
    return (f"Votre voyage {depart} - {arrivee}, aller le "
            f"{_date_fr(jour)}")


def test_les_sujets_reels_se_lisent(base):
    # Formes relevées dans la vraie boîte, orthographes comprises.
    cas = [
        ("Votre voyage St Die Des Vosges - Nancy, aller le dimanche 6 février 2022",
         "SAINT_DIE", "NANCY", "retour"),
        ("Votre voyage Nancy - St Die Des Vosges, aller le mercredi 2 février 2022",
         "NANCY", "SAINT_DIE", "aller"),
        ("Votre voyage Saint-Die-Des-Vosges - Luneville, aller le jeudi 30 juillet 2026",
         "SAINT_DIE", "LUNEVILLE", "retour"),
    ]
    for sujet, depart, arrivee, sens in cas:
        lu = lecteur.segment_du_sujet(sujet)
        assert lu is not None, sujet
        assert (lu.depart_gare, lu.arrivee_gare, lu.sens) == (depart, arrivee, sens)
        assert lu.sans_horaire


def test_le_sens_se_juge_sur_la_destination_pas_sur_le_domicile(base):
    # On part tantôt de Nancy, tantôt de Lunéville. La gare famille, elle, ne
    # change pas : c'est elle qui dit si l'on part ou si l'on rentre.
    aller = lecteur.segment_du_sujet(
        "Votre voyage Luneville - Saint-Die-Des-Vosges, aller le 12/09/2026")
    assert aller is not None and aller.sens == "aller"


def test_un_sujet_sans_voyage_n_est_pas_lu(base):
    assert lecteur.segment_du_sujet("Confirmation de votre commande") is None
    assert lecteur.segment_du_sujet("Nos meilleures offres du moment") is None


def test_un_sujet_avec_deux_fois_la_meme_gare_est_rejete(base):
    # Plutôt que d'inventer un trajet immobile.
    assert lecteur.segment_du_sujet(
        "Votre voyage Nancy - Nancy, aller le lundi 1 mars 2026") is None


def test_un_sujet_sans_date_est_rejete(base):
    assert lecteur.segment_du_sujet("Votre voyage Nancy - Saint-Dié") is None


def test_le_sujet_ne_sert_que_si_le_corps_ne_dit_rien(base):
    # Un corps exploitable l'emporte : il porte les horaires, le sujet non.
    depart = _un_jour(4).replace(hour=18, minute=12)
    lu = lecteur.analyser(_courriel(
        _billet(depart), sujet=_sujet_voyage("Nancy", "Saint-Dié", _un_jour(9))))

    assert len(lu.segments) == 1
    assert not lu.segments[0].sans_horaire
    assert lu.segments[0].depart == depart


def test_un_corps_vide_bascule_sur_le_sujet(base):
    # Le cas réel : le corps ne porte que l'horodatage du paiement.
    lu = lecteur.analyser(_courriel(
        "Votre paiement a bien été pris en compte.\neffectuee le 6 fevr. 2022, 11:36:37",
        sujet=_sujet_voyage("Nancy", "St Die Des Vosges", _un_jour(4))))

    assert lu.statut == "traite"
    assert lu.segments[0].sans_horaire
    assert lu.segments[0].sens == "aller"


# ---------------------------------------------------------------------------
# De la lecture à l'absence
# ---------------------------------------------------------------------------

def _relever_un_billet(dans_jours: int = 4, duree: int = 2,
                       identifiant: str = "<un@mail.sncf-connect.com>") -> dict:
    depart = _un_jour(dans_jours).replace(hour=18, minute=12)
    retour = _un_jour(dans_jours + duree).replace(hour=17, minute=30)
    return billets.relever(
        1, [_courriel(_billet(depart, retour), identifiant=identifiant)])


def test_un_billet_lu_declare_l_absence(client, thomas):
    bilan = _relever_un_billet()

    assert bilan["traites"] == 1
    absences = client.get("/absences", headers=thomas).json()
    assert len(absences) == 1
    assert absences[0]["origine"] == "trajet"
    assert absences[0]["lieu"] == "Saint-Dié-des-Vosges"


def test_l_absence_gele_le_menage_du_jour_couvert(client, thomas):
    client.post("/planning/placer", headers=thomas)
    _relever_un_billet()

    # ABS-5 : c'est le placement qui décroche les tâches posées sur un jour
    # devenu absent, même dans la période gelée. Sans ce second appel, le test
    # ne vérifiait rien : il passait les jours où le hasard du placement n'avait
    # rien mis sur la date couverte, et tombait les autres.
    client.post("/planning/placer", headers=thomas)

    # La comparaison se fait sur la date de Paris, pas sur le début du texte de
    # l'horodatage : une tâche du 17 à minuit s'écrit « 2026-09-16T22:00:00Z »
    # en UTC, et un startswith la rangeait au 16.
    couvert = (_un_jour(5)).date()
    planning = client.get("/planning", headers=thomas).json()

    def jour_paris(ligne: dict):
        return datetime.fromisoformat(
            ligne["debut"].replace("Z", "+00:00")).astimezone(PARIS).date()

    a_moi = [ligne for ligne in planning
             if ligne["nature"] == "tache" and ligne["id_utilisateur"] == 1
             and jour_paris(ligne) == couvert]
    assert a_moi == []


def test_les_identifiants_deja_traites_partent_avec_la_demande(client, thomas, monkeypatch):
    _relever_un_billet(identifiant="<vu@mail.sncf-connect.com>")

    recus = {}

    def faux_relever(depuis_jours=None, connus=None):
        recus["connus"] = connus
        return []

    monkeypatch.setattr(lecteur, "relever_imap", faux_relever)
    billets.relever(1)

    # Sans cela, cent soixante-dix confirmations seraient retéléchargées
    # en entier toutes les deux heures pour n'en retenir aucune.
    assert "<vu@mail.sncf-connect.com>" in recus["connus"]


def test_le_meme_courriel_n_est_lu_qu_une_fois(client, thomas):
    _relever_un_billet()
    second = _relever_un_billet()

    # BIL-1 : sans cela, chaque relève redéclarerait la même absence — et la
    # contrainte de chevauchement la refuserait, en signalant une erreur qui
    # n'en est pas une.
    assert second["deja_vus"] == 1
    assert second["traites"] == 0
    assert len(client.get("/absences", headers=thomas).json()) == 1


def test_deux_billets_qui_se_chevauchent_le_second_est_refuse(client, thomas):
    _relever_un_billet(dans_jours=4, identifiant="<a@mail.sncf-connect.com>")
    second = _relever_un_billet(dans_jours=5, identifiant="<b@mail.sncf-connect.com>")

    assert second["refuses"] == 1
    assert len(client.get("/absences", headers=thomas).json()) == 1

    a_revoir = billets.a_revoir()
    assert a_revoir and a_revoir[0]["statut"] == "refuse"


def test_un_courriel_illisible_est_conserve_avec_son_motif(client, thomas):
    corps = f"Votre billet\nALLER — {_date_fr(_un_jour(4))}\nNancy Ville 18h12 → Metz 19h00\n"
    bilan = billets.relever(1, [_courriel(corps)])

    assert bilan["illisibles"] == 1
    # BIL-8 : c'est le seul moyen de s'apercevoir que le format a changé.
    a_revoir = billets.a_revoir()
    assert len(a_revoir) == 1
    assert "Aucun trajet reconnu" in a_revoir[0]["motif"]


def _billet_sujet(depart_gare: str, arrivee_gare: str, jour, identifiant: str) -> bytes:
    """Un courriel comme les vrais : sujet parlant, corps muet."""
    return _courriel(
        "Votre paiement a bien été pris en compte.\neffectuee le 4 aout 2026, 15:50:07",
        sujet=_sujet_voyage(depart_gare, arrivee_gare, jour),
        identifiant=identifiant)


def test_un_aller_sans_horaire_gele_les_journees_certaines(client, thomas):
    depart = _un_jour(4)
    reprise = (_un_jour(9)).replace(hour=8)
    client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": "Reprise",
        "debut": reprise.isoformat(),
        "fin": (reprise + timedelta(hours=2)).isoformat(),
    })

    bilan = billets.relever(1, [
        _billet_sujet("Nancy", "St Die Des Vosges", depart, "<a@mail.sncf-connect.com>")])
    assert bilan["traites"] == 1

    absence = client.get("/absences", headers=thomas).json()[0]
    # BIL-6 : le jour du départ reste utilisable, on ne sait pas à quelle heure
    # le train part. L'absence commence au lendemain.
    assert datetime.fromisoformat(absence["debut"]).astimezone(PARIS).date() \
        == (depart + timedelta(days=1)).date()


def test_le_billet_de_retour_ferme_l_absence(client, thomas):
    depart, retour = _un_jour(4), _un_jour(8)

    billets.relever(1, [
        _billet_sujet("Nancy", "St Die Des Vosges", depart, "<a@mail.sncf-connect.com>"),
        _billet_sujet("St Die Des Vosges", "Nancy", retour, "<r@mail.sncf-connect.com>"),
    ])

    absences = client.get("/absences", headers=thomas).json()
    assert len(absences) == 1
    # Le jour du retour n'est pas gelé : on rentre on ne sait quand.
    assert datetime.fromisoformat(absences[0]["fin"]).astimezone(PARIS).date() \
        == retour.date()


def test_l_ordre_des_courriels_ne_change_rien(client, thomas):
    depart, retour = _un_jour(4), _un_jour(8)
    a_l_envers = [
        _billet_sujet("St Die Des Vosges", "Nancy", retour, "<r@mail.sncf-connect.com>"),
        _billet_sujet("Nancy", "St Die Des Vosges", depart, "<a@mail.sncf-connect.com>"),
    ]

    bilan = billets.relever(1, a_l_envers)

    # Les courriels sont traités dans l'ordre du voyage, pas dans celui de la
    # boîte : sinon l'aller se heurterait à une absence encore ouverte.
    assert bilan["traites"] == 2
    assert bilan["refuses"] == 0
    absences = client.get("/absences", headers=thomas).json()
    assert len(absences) == 1


def test_un_retour_sans_aller_connu_ne_se_plaint_pas(client, thomas):
    bilan = billets.relever(1, [
        _billet_sujet("St Die Des Vosges", "Nancy", _un_jour(4),
                      "<seul@mail.sncf-connect.com>")])

    # L'aller était peut-être hors de la fenêtre de relève. Rien à fermer,
    # rien d'anormal : le signaler ferait du bruit pour rien.
    assert bilan["traites"] == 1
    assert bilan["illisibles"] == 0
    assert client.get("/absences", headers=thomas).json() == []


def test_deux_voyages_successifs_donnent_deux_absences(client, thomas):
    messages = []
    for rang, (depart, retour) in enumerate([(2, 5), (9, 12)]):
        messages += [
            _billet_sujet("Nancy", "St Die Des Vosges", _un_jour(depart),
                          f"<a{rang}@mail.sncf-connect.com>"),
            _billet_sujet("St Die Des Vosges", "Nancy", _un_jour(retour),
                          f"<r{rang}@mail.sncf-connect.com>"),
        ]

    bilan = billets.relever(1, messages)

    assert bilan["traites"] == 4
    assert len(client.get("/absences", headers=thomas).json()) == 2


def _retour_seul(depart: datetime, identifiant: str) -> bytes:
    """Un billet de retour acheté à part, horaires compris."""
    corps = (f"Votre commande est confirmée.\n"
             f"Référence de votre dossier voyage : ZZTOPX\n\n"
             f"RETOUR — {_date_fr(depart)}\n"
             f"Saint-Dié-des-Vosges {depart:%Hh%M} → Nancy Ville "
             f"{depart + timedelta(minutes=95):%Hh%M}\n")
    return _courriel(corps, identifiant=identifiant)


def test_un_retour_achete_seul_ferme_l_absence(client, thomas):
    # Le cas de qui part sans savoir quand il rentre, puis achète son retour.
    depart = _un_jour(3).replace(hour=18, minute=0)
    billets.relever(1, [_courriel(_billet(depart),
                                  identifiant="<a@mail.sncf-connect.com>")])
    ouverte = client.get("/absences", headers=thomas).json()[0]

    retour = _un_jour(6).replace(hour=14, minute=42)
    bilan = billets.relever(1, [_retour_seul(retour, "<r@mail.sncf-connect.com>")])

    assert bilan["traites"] == 1
    assert bilan["illisibles"] == 0

    apres = client.get("/absences", headers=thomas).json()[0]
    assert apres["id_absence"] == ouverte["id_absence"]
    # Fermée à l'heure d'arrivée, puisqu'on la connaît cette fois.
    assert datetime.fromisoformat(apres["fin"]) == retour + timedelta(minutes=95)


def test_un_retour_seul_sans_absence_ouverte_ne_gene_pas(client, thomas):
    bilan = billets.relever(
        1, [_retour_seul(_un_jour(4).replace(hour=14), "<x@mail.sncf-connect.com>")])

    assert bilan["traites"] == 1
    assert client.get("/absences", headers=thomas).json() == []


def test_reessayer_oublie_les_rates_mais_pas_les_reussis(client, thomas):
    depart = _un_jour(4).replace(hour=18, minute=12)
    billets.relever(1, [
        _courriel(_billet(depart), identifiant="<ok@mail.sncf-connect.com>"),
        _courriel(f"billet\nALLER — {_date_fr(depart)}\nNancy 18h12 → Metz 19h00",
                  identifiant="<rate@mail.sncf-connect.com>"),
    ])

    assert billets.oublier_les_rates() == 1

    # Corriger le lecteur ne sert à rien si les courriels ratés restent
    # marqués comme vus. Les réussis, eux, recréeraient une absence en double.
    relu = billets.relever(1, [
        _courriel(_billet(depart), identifiant="<ok@mail.sncf-connect.com>"),
        _courriel(f"billet\nALLER — {_date_fr(depart)}\nNancy 18h12 → Metz 19h00",
                  identifiant="<rate@mail.sncf-connect.com>"),
    ])
    assert relu["deja_vus"] == 1
    assert relu["illisibles"] == 1


def test_reessayer_passe_par_l_api(client, thomas):
    depart = _un_jour(4)
    billets.relever(1, [_courriel(
        f"billet\nALLER — {_date_fr(depart)}\nNancy 18h12 → Metz 19h00")])

    reponse = client.delete("/trajets/courriels/a-revoir", headers=thomas)
    assert reponse.json()["oublies"] == 1
    assert client.get("/trajets/courriels/a-revoir", headers=thomas).json() == []


def test_seul_l_administrateur_reessaie(client, lorette):
    assert client.delete("/trajets/courriels/a-revoir",
                         headers=lorette).status_code == 403


def test_un_courriel_ignore_ne_demande_pas_de_correction(client, thomas):
    billets.relever(1, [_courriel("Nos offres du moment", de="pub@example.com")])
    assert billets.a_revoir() == []


def test_la_releve_rend_compte_de_chaque_courriel(client, thomas):
    depart = _un_jour(4).replace(hour=18, minute=12)
    bilan = billets.relever(1, [
        _courriel(_billet(depart, _un_jour(6).replace(hour=17)),
                  identifiant="<1@mail.sncf-connect.com>"),
        _courriel("Nos offres", de="pub@ailleurs.fr", identifiant="<2@x>"),
        _courriel(f"billet\nALLER — {_date_fr(depart)}\nNancy 18h12 → Metz 19h00",
                  identifiant="<3@mail.sncf-connect.com>"),
    ])

    assert bilan["lus"] == 3
    assert (bilan["traites"], bilan["ignores"], bilan["illisibles"]) == (1, 1, 1)


def test_le_resume_signale_ce_qu_on_n_a_pas_su_lire(base):
    texte = billets.resume({"traites": 1, "ignores": 4, "illisibles": 2, "refuses": 0})
    assert "1 billet(s) lu(s)" in texte
    assert "pas su lire" in texte
    # Les courriels ignorés ne méritent pas d'être comptés : ce sont des
    # publicités, et les nommer chaque fois ferait du bruit.
    assert "4" not in texte


def test_une_boite_vide_ne_dit_rien_d_inquietant(base):
    assert billets.resume({"traites": 0, "ignores": 0,
                           "illisibles": 0, "refuses": 0}) == "Rien de neuf dans la boîte."


def test_la_releve_automatique_previent(client, thomas):
    billets.relever(1, [_courriel(_billet(_un_jour(4).replace(hour=18, minute=12)))],
                    annoncer=True)

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        alertes = conn.execute(
            "SELECT contenu FROM notification WHERE type = 'alerte'").fetchall()

    # BIL-9 : une absence déclarée sans qu'on l'ait demandée doit s'annoncer.
    # BIL-11 : elle dit où l'on va, quand, et ce qui est gelé.
    assert len(alertes) == 1
    assert "Saint-Dié" in alertes[0]["contenu"]
    assert "Absence notée" in alertes[0]["contenu"]


def test_la_releve_manuelle_ne_previent_pas(client, thomas):
    billets.relever(1, [_courriel(_billet(_un_jour(4).replace(hour=18, minute=12)))])

    with psycopg.connect(_url()) as conn:
        alertes = conn.execute(
            "SELECT count(*) FROM notification WHERE type = 'alerte'").fetchone()[0]
    assert alertes == 0


def test_annuler_un_billet_rend_les_jours_au_menage(client, thomas):
    _relever_un_billet()
    voyages = billets.absences_issues_de_billets()
    assert len(voyages) == 1

    from api import trajets
    trajets.oublier(voyages[0]["id_absence"])

    assert client.get("/absences", headers=thomas).json() == []


# ---------------------------------------------------------------------------
# Par l'API
# ---------------------------------------------------------------------------

def test_la_releve_passe_par_l_api(client, thomas):
    depart = _un_jour(4).replace(hour=18, minute=12)
    encode = base64.b64encode(
        _courriel(_billet(depart, _un_jour(6).replace(hour=17)))).decode()

    reponse = client.post("/trajets/courriels", headers=thomas,
                          json={"messages": [encode]})
    assert reponse.status_code == 200
    assert reponse.json()["traites"] == 1


def test_sans_boite_configuree_l_api_le_dit(client, thomas):
    # Aucun message injecté : la vraie boîte est sollicitée, et il n'y en a pas.
    reponse = client.post("/trajets/courriels", headers=thomas)
    assert reponse.status_code == 503
    assert reponse.json()["code"] == "boite_absente"


def test_seul_l_administrateur_releve_la_boite(client, lorette):
    assert client.post("/trajets/courriels", headers=lorette,
                       json={"messages": []}).status_code == 403


def test_les_courriels_a_revoir_s_exposent(client, thomas):
    corps = f"billet\nALLER — {_date_fr(_un_jour(4))}\nNancy 18h12 → Metz 19h00"
    billets.relever(1, [_courriel(corps)])

    a_revoir = client.get("/trajets/courriels/a-revoir", headers=thomas).json()
    assert len(a_revoir) == 1
    assert a_revoir[0]["statut"] == "illisible"


def test_une_charge_base64_invalide_est_refusee(client, thomas):
    reponse = client.post("/trajets/courriels", headers=thomas,
                          json={"messages": ["pas du base64 !!"]})
    assert reponse.status_code == 400


@pytest.mark.parametrize("brut", [b"", b"\xff\xfe\x00", b"Subject: seul"])
def test_aucun_courriel_ne_fait_tomber_la_releve(client, thomas, brut):
    # La relève tourne sans surveillance : une exception ferait perdre tous
    # les courriels suivants.
    bilan = billets.relever(1, [brut])
    assert bilan["lus"] == 1


# ---------------------------------------------------------------------------
# Deux boîtes, et tout voyage se dit                        (BIL-10, BIL-11)
# ---------------------------------------------------------------------------

def test_chaque_boite_a_son_proprietaire(client, thomas, monkeypatch):
    """BIL-10 : un billet lu dans sa boîte à elle est son voyage à elle."""
    from api.config import configuration

    conf = configuration()
    anciens = (conf.imap_hote, conf.imap_utilisateur, conf.imap_mot_de_passe,
               conf.imap2_hote, conf.imap2_utilisateur, conf.imap2_mot_de_passe,
               conf.imap2_pseudo)
    conf.imap_hote, conf.imap_utilisateur, conf.imap_mot_de_passe = "a", "a", "a"
    conf.imap2_hote, conf.imap2_utilisateur, conf.imap2_mot_de_passe = "b", "b", "b"
    conf.imap2_pseudo = "lorette"

    depart = _un_jour(5).replace(hour=18, minute=12)
    boites = {"a": [_courriel(_billet(depart))],
              "b": [_courriel(_billet(depart + timedelta(days=7)),
                              identifiant="<sien@mail.sncf-connect.com>")]}

    def faux_relever(depuis_jours=None, connus=None, boite_lue=None):
        return boites[boite_lue["hote"]]

    monkeypatch.setattr(lecteur, "relever_imap", faux_relever)
    try:
        bilan = billets.relever()
    finally:
        (conf.imap_hote, conf.imap_utilisateur, conf.imap_mot_de_passe,
         conf.imap2_hote, conf.imap2_utilisateur, conf.imap2_mot_de_passe,
         conf.imap2_pseudo) = anciens

    assert bilan["traites"] == 2
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        absences = conn.execute(
            "SELECT u.pseudo, lower(a.periode) AS debut FROM absence a "
            "  JOIN utilisateur u USING (id_utilisateur) ORDER BY lower(a.periode)"
        ).fetchall()

    assert [a["pseudo"] for a in absences] == ["thomas", "lorette"]


def test_l_annonce_dit_ou_et_quand(client, thomas):
    """BIL-11 : le voyage est nommé, avec ses dates et ce qui est gelé."""
    depart = _un_jour(6).replace(hour=9, minute=10)
    courriel = _courriel(_billet(depart, retour=depart + timedelta(days=2)))

    billets.relever(1, [courriel], annoncer=True)

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        alerte = conn.execute(
            "SELECT contenu FROM notification WHERE type = 'alerte'").fetchone()

    assert alerte is not None
    assert "Saint-Dié" in alerte["contenu"]
    assert f"{depart:%d/%m}" in alerte["contenu"]
    assert "Absence notée" in alerte["contenu"]


# ---------------------------------------------------------------------------
# Le format d'aujourd'hui                                  (BIL-12 à BIL-15)
#
# Depuis 2025, une confirmation ne décrit qu'un trajet. Les deux gares sont
# dans le sujet, l'heure de départ dans une cellule du corps, et l'arrivée
# nulle part. Le mot « Aller » figure sur les deux courriels d'un aller-retour.
#
# Les courriels fabriqués ici reprennent la mise en page des vrais, tables
# comprises : c'est justement l'empilement de cellules qui avait fait échouer
# l'ancien appariement gare-heure-gare-heure.
# ---------------------------------------------------------------------------

JOURS = ("lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche")


# La version texte des vraies confirmations, celle que tout lecteur de courriel
# préfère : deux phrases et l'horodatage du paiement. Pas une gare, pas un
# horaire. Pendant des mois, c'est la seule qu'on lisait.
TEXTE_MUET = """Bonjour,

Votre commande est confirmée. Retrouvez votre billet dans l'application
SNCF Connect ou sur votre espace Mon Voyage.

Paiement effectué le 30 sept. 2026, 08:20:40.
Merci et bon voyage.
"""


def _confirmation(depart_gare: str, arrivee_gare: str, quand: datetime, *,
                  reference: str = "QQRQCW", train: str = "TER 834115",
                  identifiant: str = "<vrai@connect.sncf>") -> bytes:
    """Une confirmation telle que SNCF Connect l'envoie : deux versions.

    Le texte brut ne dit rien, le HTML porte le récapitulatif. C'est cette
    paire, et non le HTML seul, qui reproduit le défaut : lire la version
    préférée et s'arrêter là, c'est ne jamais voir l'heure de départ.
    """
    jour = JOURS[quand.weekday()]
    corps = f"""<html><body><table>
<tr><td>Merci</td><td>Et bon voyage !</td></tr>
<tr><td>Pour avoir plus de détails sur votre réservation, la compléter, la
        modifier ou l'annuler, rendez-vous sur votre espace Mon Voyage.</td></tr>
<tr><td>Votre voyage</td><td>{depart_gare} {arrivee_gare}</td><td>9,70 €</td></tr>
<tr><td>Aller : {jour} {_date_fr(quand)} à {quand:%H:%M}</td></tr>
<tr><td>Référence<br>{reference}</td><td>Nom<br>Mathis</td></tr>
<tr><td>ALLER<br>TRAIN {train} | BILLET TITULAIRE CARTE FLUO JEUNE</td></tr>
<tr><td>Effectuée le 30 sept. 2026, 08:20:40</td>
    <td>Référence commande {reference} / HP5331657780</td></tr>
</table></body></html>"""

    message = EmailMessage()
    message["From"] = "SNCF Connect <noreply@connect.sncf>"
    message["To"] = "thomas@example.org"
    message["Subject"] = (f"Votre voyage {depart_gare} - {arrivee_gare}, "
                          f"aller le {jour} {_date_fr(quand)}")
    message["Message-ID"] = identifiant
    message["Date"] = format_datetime(datetime.now(PARIS))
    message.set_content(TEXTE_MUET)
    message.add_alternative(corps, subtype="html")
    return message.as_bytes()


def _trains_au_planning() -> list[str]:
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        return [ligne["libelle"] for ligne in conn.execute(
            "SELECT libelle FROM occupation WHERE cle_externe LIKE 'trajet-%' "
            " ORDER BY lower(periode)").fetchall()]


def test_une_confirmation_actuelle_se_lit(base):
    quand = _un_jour(4).replace(hour=13, minute=3)

    lu = lecteur.analyser(_confirmation("Nancy", "Saint-Die-Des-Vosges", quand))

    assert lu.statut == "traite"
    assert lu.reference == "QQRQCW"
    assert lu.train == "TER 834115"
    assert len(lu.segments) == 1
    trajet = lu.segments[0]
    assert (trajet.depart_gare, trajet.arrivee_gare) == ("NANCY", "SAINT_DIE")
    # L'heure de départ est lue, pas devinée : c'est tout l'enjeu.
    assert trajet.depart == quand
    assert not trajet.sans_horaire
    # L'arrivée, elle, n'est écrite nulle part. Elle est estimée et le dit.
    assert trajet.duree_estimee
    assert trajet.arrivee > trajet.depart


def test_le_mot_aller_du_courriel_ne_dit_pas_le_sens(base):
    # BIL-13 : les deux billets d'un aller-retour portent « Aller ». Pour la
    # SNCF chaque trajet est un voyage ; pour nous, un seul est un départ.
    quand = _un_jour(6).replace(hour=9, minute=6)

    lu = lecteur.analyser(_confirmation("Saint-Die-Des-Vosges", "Nancy", quand,
                                        reference="HY2F2R", train="TER 834122"))

    assert lu.segments[0].sens == "retour"
    # Et une référence peut mêler lettres et chiffres.
    assert lu.reference == "HY2F2R"


def test_une_gare_inconnue_du_sujet_est_acceptee(base):
    # BIL-14 : Metz n'est ni le domicile ni la famille, et n'a aucune variante
    # connue. Taire le voyage serait pire que de garder son nom tel quel.
    quand = _un_jour(3).replace(hour=8, minute=45)

    lu = lecteur.analyser(_confirmation("Nancy", "METZ", quand, reference="ZZ12AB"))

    assert lu.statut == "traite"
    assert lu.segments[0].arrivee_gare == "Metz"
    assert lu.segments[0].sens == "aller"
    assert lu.segments[0].depart == quand


def test_un_aller_retour_arrive_en_deux_courriels(client, thomas):
    # BIL-15 : le voyage se recompose. L'aller ouvre l'absence à son heure, le
    # retour la raccorde à la sienne.
    aller = _un_jour(4).replace(hour=13, minute=3)
    retour = _un_jour(6).replace(hour=9, minute=6)

    bilan = billets.relever(1, [
        _confirmation("Nancy", "Saint-Die-Des-Vosges", aller,
                      identifiant="<aller@connect.sncf>"),
        _confirmation("Saint-Die-Des-Vosges", "Nancy", retour, reference="HY2F2R",
                      train="TER 834122", identifiant="<retour@connect.sncf>"),
    ], annoncer=True)

    assert (bilan["traites"], bilan["illisibles"], bilan["refuses"]) == (2, 0, 0)

    absences = client.get("/absences", headers=thomas).json()
    assert len(absences) == 1
    assert datetime.fromisoformat(absences[0]["debut"]) == aller
    fin = datetime.fromisoformat(absences[0]["fin"])
    # Fermée le jour du retour, après son départ : ni la veille, ni le lundi
    # suivant comme le faisait la fin devinée.
    assert fin.astimezone(PARIS).date() == retour.date()
    assert fin > retour

    # TRJ-11 : les deux trains s'affichent.
    assert len(_trains_au_planning()) == 2

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        alerte = conn.execute(
            "SELECT contenu FROM notification WHERE type = 'alerte' "
            " ORDER BY id_notification DESC LIMIT 1").fetchone()
    assert f"départ le {aller:%d/%m à %Hh%M}" in alerte["contenu"]
    assert f"départ le {retour:%d/%m à %Hh%M}" in alerte["contenu"]


def test_le_retour_le_jour_du_depart_efface_l_absence(client, thomas):
    # TRJ-10 par deux courriels : l'aller seul ne pouvait que supposer une nuit
    # dehors. Le retour du soir montre qu'il n'y en a pas.
    aller = _un_jour(5).replace(hour=8, minute=0)
    retour = _un_jour(5).replace(hour=19, minute=0)

    bilan = billets.relever(1, [
        _confirmation("Nancy", "Saint-Die-Des-Vosges", aller,
                      identifiant="<a1@connect.sncf>"),
        _confirmation("Saint-Die-Des-Vosges", "Nancy", retour, reference="HY2F2R",
                      identifiant="<r1@connect.sncf>"),
    ])

    assert bilan["traites"] == 2
    assert client.get("/absences", headers=thomas).json() == []
    # La journée reste occupée par les trains : elle saute, sans être gelée.
    assert len(_trains_au_planning()) == 2


def test_un_retour_orphelin_n_allonge_rien(client, thomas):
    # Un retour dont l'aller est hors de la fenêtre de relève : le train
    # s'affiche, et aucune absence n'est inventée ni déplacée.
    bilan = billets.relever(1, [
        _confirmation("Saint-Die-Des-Vosges", "Nancy",
                      _un_jour(4).replace(hour=17, minute=30),
                      identifiant="<orphelin@connect.sncf>")])

    assert bilan["traites"] == 1
    assert client.get("/absences", headers=thomas).json() == []
    assert len(_trains_au_planning()) == 1


def test_un_billet_pour_ailleurs_est_annonce(client, thomas):
    # BIL-11 et BIL-14 ensemble : le voyage compte, et il est nommé.
    depart = _un_jour(4).replace(hour=8, minute=45)

    billets.relever(1, [_confirmation("Nancy", "Metz", depart,
                                      identifiant="<metz@connect.sncf>")],
                    annoncer=True)

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        alerte = conn.execute(
            "SELECT contenu FROM notification WHERE type = 'alerte'").fetchone()
    assert "Metz" in alerte["contenu"]
    assert f"{depart:%d/%m à %Hh%M}" in alerte["contenu"]


def test_le_detail_du_train_porte_le_numero_et_la_reference(client, thomas):
    billets.relever(1, [_confirmation("Nancy", "Saint-Die-Des-Vosges",
                                      _un_jour(4).replace(hour=13, minute=3),
                                      identifiant="<detail@connect.sncf>")])

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        details = conn.execute(
            "SELECT details FROM occupation WHERE cle_externe LIKE 'trajet-%'"
        ).fetchone()["details"]

    # Ce qu'on cherche sur le quai, et non un « Billet » muet.
    assert "TER 834115" in details
    assert "QQRQCW" in details


def test_l_heure_est_dans_la_version_qu_on_ne_lisait_pas(base):
    # BIL-16 : le défaut qui faisait annoncer « départ à 00h00 ». La version
    # texte, celle que tout lecteur préfère, ne porte ni gare ni horaire.
    quand = _un_jour(4).replace(hour=13, minute=3)
    message = email.message_from_bytes(
        _confirmation("Nancy", "Saint-Die-Des-Vosges", quand),
        policy=email.policy.default)

    versions = lecteur.corps_lisibles(message)

    assert len(versions) == 2
    assert "13:03" not in versions[0], "la version préférée ne dit pas l'heure"
    assert "13:03" in versions[1]


def test_un_billet_dont_le_voyage_est_passe_ne_declare_rien(client, thomas):
    # BIL-17 : la relève regarde un mois en arrière. Un billet de la semaine
    # dernière n'a rien à geler, et rien à annoncer non plus.
    passe = _un_jour(-7).replace(hour=9, minute=0)

    bilan = billets.relever(1, [_confirmation("Nancy", "Metz", passe,
                                              identifiant="<vieux@connect.sncf>")],
                            annoncer=True)

    assert (bilan["traites"], bilan["passes"]) == (1, 1)
    assert client.get("/absences", headers=thomas).json() == []
    texte = billets.resume(bilan)
    assert texte.startswith("Rien de neuf dans la boîte.")
    # Mais la relève dit ce qu'elle a vu : un « rien » muet cacherait aussi
    # bien une boîte illisible qu'une boîte vide.
    assert "1 voyage passé" in texte

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        alertes = conn.execute(
            "SELECT count(*) AS n FROM notification WHERE type = 'alerte'").fetchone()
    assert alertes["n"] == 0


def test_un_billet_passe_est_quand_meme_classe(client, thomas):
    # Classé, pour ne pas être relu à chaque relève, et avec son motif.
    bilan = billets.relever(1, [_confirmation("Nancy", "Saint-Die-Des-Vosges",
                                              _un_jour(-3).replace(hour=8),
                                              identifiant="<range@connect.sncf>")])

    assert bilan["traites"] == 1
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        garde = conn.execute(
            "SELECT statut, motif FROM courriel").fetchone()
    assert garde["statut"] == "traite"
    assert "passé" in garde["motif"]


def test_tout_relire_rouvre_meme_les_courriels_classes(client, thomas):
    """Ce que « réessayer » ne savait pas faire : rouvrir un billet mal lu.

    Un courriel traité de travers ne se signale nulle part. Tant qu'il reste
    marqué comme vu, corriger le lecteur ne change rien pour lui.
    """
    aller = _un_jour(4).replace(hour=13, minute=3)
    billets.relever(1, [_confirmation("Nancy", "Saint-Die-Des-Vosges", aller,
                                      identifiant="<lu@connect.sncf>")])
    assert client.get("/absences", headers=thomas).json()

    efface = billets.relire_les_billets()

    assert efface == {"absences_rendues": 1, "courriels_oublies": 1}
    # L'absence et son train sont rendus : ils seront recréés à la relecture.
    assert client.get("/absences", headers=thomas).json() == []
    assert _trains_au_planning() == []

    relu = billets.relever(1, [_confirmation("Nancy", "Saint-Die-Des-Vosges", aller,
                                             identifiant="<lu@connect.sncf>")])
    assert relu["deja_vus"] == 0
    assert relu["traites"] == 1
    assert client.get("/absences", headers=thomas).json()


def test_tout_relire_laisse_le_passe_tranquille(client, thomas):
    passe = _un_jour(-5).replace(hour=9)
    billets.relever(1, [_confirmation("Nancy", "Metz", passe,
                                      identifiant="<passe@connect.sncf>")])

    efface = billets.relire_les_billets(jours=2)

    # Reçu il y a moins de deux jours dans les tests, mais sans absence à
    # rendre : un voyage passé n'en avait pas créé.
    assert efface["absences_rendues"] == 0


def test_la_releve_dit_ce_qu_elle_a_vu(base):
    texte = billets.resume({"lus": 9, "traites": 2, "passes": 2, "deja_vus": 6,
                            "ignores": 1, "illisibles": 0, "refuses": 0,
                            "voyages": []})

    assert texte.startswith("Rien de neuf dans la boîte.")
    assert "9 courriel(s) relevé(s)" in texte
    assert "6 déjà vus" in texte
    assert "2 voyages passés" in texte


def test_les_deux_billets_d_un_voyage_ne_font_qu_une_ligne(client, thomas):
    # L'aller et le retour arrivent séparément et pointent sur la même absence.
    # Deux lignes donneraient deux boutons pour annuler la même chose.
    aller = _un_jour(4).replace(hour=13, minute=3)
    retour = _un_jour(6).replace(hour=9, minute=6)
    billets.relever(1, [
        _confirmation("Nancy", "Saint-Die-Des-Vosges", aller,
                      identifiant="<a2@connect.sncf>"),
        _confirmation("Saint-Die-Des-Vosges", "Nancy", retour, reference="HY2F2R",
                      identifiant="<r2@connect.sncf>"),
    ])

    voyages = billets.absences_issues_de_billets()

    assert len(voyages) == 1
    # Mais les deux références sont là : c'est ce qu'on cherche dans sa boîte.
    assert voyages[0]["references"] == "HY2F2R, QQRQCW"
    assert voyages[0]["retour_connu"] is True


def test_un_aller_seul_annonce_une_fin_supposee(client, thomas):
    billets.relever(1, [_confirmation("Nancy", "Saint-Die-Des-Vosges",
                                      _un_jour(4).replace(hour=13, minute=3),
                                      identifiant="<seul2@connect.sncf>")])

    voyages = billets.absences_issues_de_billets()

    # TRJ-7 : sans retour, la fin vient de la prochaine obligation connue. Le
    # bot le dit, au lieu de donner une date devinée comme une date lue.
    assert voyages[0]["retour_connu"] is False


# ---------------------------------------------------------------------------
# L'heure d'arrivée, demandée à la SNCF                                 BIL-21
# ---------------------------------------------------------------------------

def _periode_du_trajet(sens: str = "aller") -> tuple[datetime, datetime]:
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        ligne = conn.execute(
            "SELECT lower(periode) AS depart, upper(periode) AS arrivee "
            "  FROM trajet WHERE sens = %s ORDER BY id_trajet LIMIT 1",
            (sens,)).fetchone()
    return ligne["depart"], ligne["arrivee"]


def test_l_heure_d_arrivee_vient_de_la_sncf(client, thomas, monkeypatch):
    # Le courriel ne la donne pas, et elle dépend du train : un direct et un
    # avec correspondance ne rentrent pas à la même heure.
    from api.collecteurs import sncf

    aller = _un_jour(4).replace(hour=13, minute=3)
    vrai = sncf.Trajet(depart=aller, arrivee=aller + timedelta(minutes=77),
                       correspondances=0, resume="TER direct")
    monkeypatch.setattr("api.billets.sncf.chercher", lambda *a, **k: [vrai])

    billets.relever(1, [_confirmation("Nancy", "Saint-Die-Des-Vosges", aller,
                                      identifiant="<horaire@connect.sncf>")])

    depart, arrivee = _periode_du_trajet()
    assert depart == aller
    assert arrivee == aller + timedelta(minutes=77)


def test_un_train_a_une_autre_heure_n_est_pas_le_bon(client, thomas, monkeypatch):
    # Prendre le train d'après parce qu'il est proche donnerait une arrivée
    # fausse avec l'air d'avoir été lue.
    from api.collecteurs import sncf

    aller = _un_jour(4).replace(hour=13, minute=3)
    autre = sncf.Trajet(depart=aller + timedelta(hours=2),
                        arrivee=aller + timedelta(hours=3, minutes=20),
                        correspondances=1, resume="TER, 1 correspondance")
    monkeypatch.setattr("api.billets.sncf.chercher", lambda *a, **k: [autre])

    billets.relever(1, [_confirmation("Nancy", "Saint-Die-Des-Vosges", aller,
                                      identifiant="<autre@connect.sncf>")])

    _, arrivee = _periode_du_trajet()
    assert arrivee < aller + timedelta(hours=2)


def test_sans_reponse_de_la_sncf_l_arrivee_reste_estimee(client, thomas, monkeypatch):
    # Mieux vaut une fin approximative qu'un voyage non déclaré.
    from api.collecteurs import sncf

    def injoignable(*args, **nommes):
        raise sncf.TrajetImpossible("injoignable", "API SNCF injoignable")

    monkeypatch.setattr("api.billets.sncf.chercher", injoignable)
    aller = _un_jour(4).replace(hour=13, minute=3)

    bilan = billets.relever(1, [_confirmation("Nancy", "Saint-Die-Des-Vosges", aller,
                                              identifiant="<panne@connect.sncf>")])

    assert bilan["traites"] == 1
    depart, arrivee = _periode_du_trajet()
    assert depart == aller
    assert timedelta(minutes=30) < arrivee - depart < timedelta(hours=3)


# ---------------------------------------------------------------------------
# La boîte décide du titulaire, pas celui qui relève                    BIL-10
# ---------------------------------------------------------------------------

@pytest.fixture
def deux_boites(monkeypatch):
    """Deux boîtes configurées, chacune avec un billet et son propriétaire."""
    from api.config import configuration

    conf = configuration()
    champs = ("imap_hote", "imap_utilisateur", "imap_mot_de_passe", "imap_pseudo",
              "imap2_hote", "imap2_utilisateur", "imap2_mot_de_passe", "imap2_pseudo")
    anciens = {c: getattr(conf, c) for c in champs}
    conf.imap_hote = conf.imap_utilisateur = conf.imap_mot_de_passe = "a"
    conf.imap2_hote = conf.imap2_utilisateur = conf.imap2_mot_de_passe = "b"
    conf.imap_pseudo, conf.imap2_pseudo = "thomas", "lorette"

    depart = _un_jour(5).replace(hour=18, minute=12)
    contenu = {"a": [_courriel(_billet(depart))],
               "b": [_courriel(_billet(depart + timedelta(days=7)),
                               identifiant="<sien@mail.sncf-connect.com>")]}
    monkeypatch.setattr(
        lecteur, "relever_imap",
        lambda depuis_jours=None, connus=None, boite_lue=None: contenu[boite_lue["hote"]])
    yield conf
    for champ, valeur in anciens.items():
        setattr(conf, champ, valeur)


def _voyageurs() -> list[str]:
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        return [ligne["pseudo"] for ligne in conn.execute(
            "SELECT u.pseudo FROM absence a JOIN utilisateur u USING (id_utilisateur) "
            " ORDER BY lower(a.periode)").fetchall()]


def _id_de(pseudo: str) -> int:
    with psycopg.connect(_url()) as conn:
        return conn.execute("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s",
                            (pseudo,)).fetchone()[0]


def test_relever_a_la_main_ne_s_approprie_pas_les_billets_de_l_autre(
        client, thomas, deux_boites):
    # Le défaut : « /billets » tapé par Thomas rattachait tout à Thomas, et son
    # planning se gelait pour le voyage de Lorette. La relève de la nuit, elle,
    # ne passait personne et tombait juste, ce qui cachait le problème.
    bilan = billets.relever(_id_de("thomas"))

    assert bilan["traites"] == 2
    assert _voyageurs() == ["thomas", "lorette"]


def test_lorette_qui_releve_ne_prend_pas_les_billets_de_thomas(
        client, thomas, deux_boites):
    billets.relever(_id_de("lorette"))

    assert _voyageurs() == ["thomas", "lorette"]


def test_une_boite_sans_proprietaire_revient_a_celui_qui_releve(
        client, thomas, deux_boites):
    # Le repli d'avant, conservé : sans pseudo sur la boîte, il faut bien
    # choisir quelqu'un, et celui qui demande est le meilleur candidat.
    deux_boites.imap_pseudo = ""
    deux_boites.imap2_hote = ""

    billets.relever(_id_de("lorette"))

    assert _voyageurs() == ["lorette"]
