"""Envoyer par le service de notifications d'Apple                (NOT-16, NOT-19)

Une notification est écrite en base d'abord (NOT-2), puis ce module la porte à
chaque iPhone où le compte est connecté. Le bot garde sa propre file : les deux
voies vivent côte à côte jusqu'à la bascule complète vers l'appli.

Apple demande un jeton signé par la clé du compte développeur (ES256), valable
une heure. On le garde quarante minutes, et on le refait si Apple le refuse.

Sans clé configurée, rien ne part et rien ne se perd : les notifications
attendent, et celles de plus d'un jour sont marquées périmées plutôt que de
tomber toutes d'un coup le jour où la clé arrive.
"""

from __future__ import annotations

import base64
import json
import logging
import re
import time
from dataclasses import dataclass

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from api.base import executer, lister
from api.config import configuration

LOG = logging.getLogger(__name__)

HOTES = {
    "production": "https://api.push.apple.com",
    "developpement": "https://api.sandbox.push.apple.com",
}

# Ce qu'on lit en haut de la notification, sur l'écran verrouillé.
TITRES = {
    "bilan": "Ta journée",
    "rappel": "C'est fait ?",
    "coach": "HAL",
    "changement": "Planning",
    "sport": "Sport",
    "alerte": "À regarder",
    "demande": "À accepter",
}

# ACC-14 : la catégorie qui porte Accepter et Refuser, déclarée par l'appli.
CATEGORIE_DEMANDE = "DEMANDE"

# Apple refuse une charge de plus de 4 Ko. Le bilan du matin fait parfois une
# page : l'écran verrouillé n'en montre que le début, l'appli montre le reste.
MAX_CORPS = 1800
ESSAIS_MAX = 5
DUREE_JETON = 40 * 60

# Ce qu'Apple répond quand le jeton d'un iPhone ne vaut plus rien : l'appli a
# été supprimée, ou le jeton appartient à une autre appli.
JETONS_MORTS = {"BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"}
JETON_FOURNISSEUR_REFUSE = {"ExpiredProviderToken", "InvalidProviderToken"}


def configuree() -> bool:
    conf = configuration()
    return bool(conf.apns_cle and conf.apns_id_cle and conf.apns_equipe and conf.apns_sujet)


# ---------------------------------------------------------------------------
# Le jeton du fournisseur
# ---------------------------------------------------------------------------

def _b64(donnees: bytes) -> str:
    return base64.urlsafe_b64encode(donnees).rstrip(b"=").decode()


def _cle_privee() -> ec.EllipticCurvePrivateKey:
    """La clé `.p8`, donnée telle quelle ou en base64 sur une ligne dans le .env."""
    brute = configuration().apns_cle.strip()
    if "BEGIN" in brute:
        pem = brute.replace("\\n", "\n").encode()
    else:
        pem = base64.b64decode(brute)
    cle = serialization.load_pem_private_key(pem, password=None)
    if not isinstance(cle, ec.EllipticCurvePrivateKey):
        raise ValueError("La clé APNs doit être une clé ES256")
    return cle


@dataclass
class _Jeton:
    valeur: str = ""
    cree_le: float = 0.0


_jeton = _Jeton()


def jeton_fournisseur(maintenant: float | None = None) -> str:
    instant = maintenant if maintenant is not None else time.time()
    if _jeton.valeur and instant - _jeton.cree_le < DUREE_JETON:
        return _jeton.valeur

    conf = configuration()
    entete = _b64(json.dumps({"alg": "ES256", "kid": conf.apns_id_cle},
                             separators=(",", ":")).encode())
    corps = _b64(json.dumps({"iss": conf.apns_equipe, "iat": int(instant)},
                            separators=(",", ":")).encode())
    signature_der = _cle_privee().sign(f"{entete}.{corps}".encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(signature_der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")

    _jeton.valeur = f"{entete}.{corps}.{_b64(signature)}"
    _jeton.cree_le = instant
    return _jeton.valeur


def oublier_le_jeton() -> None:
    _jeton.valeur, _jeton.cree_le = "", 0.0


# ---------------------------------------------------------------------------
# La charge
# ---------------------------------------------------------------------------

def lien(notification: dict) -> dict:
    """NOT-19 : où l'appli s'ouvre quand on touche la notification."""
    if notification.get("id_demande"):
        return {"ecran": "demandes", "id": notification["id_demande"]}
    if notification["type"] == "coach" or notification.get("id_echange"):
        return {"ecran": "hal"}
    if notification.get("id_invitation"):
        return {"ecran": "seance", "id_invitation": notification["id_invitation"]}
    if notification.get("id_proposition"):
        return {"ecran": "proposition", "id": notification["id_proposition"]}
    if notification.get("id_occurrence"):
        ecran = "seance" if notification.get("categorie") == "sport" else "tache"
        return {"ecran": ecran, "id": notification["id_occurrence"]}
    if notification["type"] == "changement" and notification.get("operation"):
        return {"ecran": "historique", "operation": notification["operation"]}
    if notification["type"] == "sport":
        return {"ecran": "semaine"}
    return {"ecran": "aujourdhui"}


def _texte(contenu: str) -> str:
    """Le texte nu : ni balises du bot, ni gras en astérisques."""
    texte = re.sub(r"<[^>]+>", "", contenu).replace("**", "")
    return texte if len(texte) <= MAX_CORPS else texte[:MAX_CORPS - 1].rstrip() + "…"


def charge(notification: dict) -> dict:
    rendu = {
        "aps": {
            "alert": {"title": TITRES.get(notification["type"], "HAL"),
                      "body": _texte(notification["contenu"])},
            "sound": "default",
            # Les notifications d'un même genre se rangent ensemble.
            "thread-id": notification["type"],
        },
        "hal": {
            "id_notification": notification["id_notification"],
            "type": notification["type"],
            "lien": lien(notification),
        },
    }
    if notification.get("id_demande"):
        # ACC-14 : Accepter et Refuser, sans ouvrir l'appli.
        rendu["aps"]["category"] = CATEGORIE_DEMANDE
        rendu["hal"]["id_demande"] = notification["id_demande"]
    return rendu


# ---------------------------------------------------------------------------
# La file
# ---------------------------------------------------------------------------

def _ranger() -> None:
    """Ce qui ne partira jamais : trop vieux, ou personne pour le recevoir."""
    executer("""UPDATE notification SET apple_statut = 'perimee'
                 WHERE apple_statut = 'a_envoyer' AND date_creation < now() - INTERVAL '1 day'""")
    executer("""UPDATE notification n SET apple_statut = 'sans_appareil'
                 WHERE n.apple_statut = 'a_envoyer'
                   AND NOT EXISTS (SELECT 1 FROM appareil a
                                    WHERE a.id_utilisateur = n.id_utilisateur)""")


def a_envoyer(limite: int = 50) -> list[dict]:
    """NOT-14 : pendant son silence, un compte ne reçoit que HAL, et seulement s'il
    lui a écrit il y a moins de trente minutes."""
    return lister(
        """
        SELECT n.id_notification, n.id_utilisateur, n.type, n.contenu, n.id_occurrence,
               n.id_proposition, n.id_invitation, n.id_echange, n.operation, n.apple_essais,
               n.id_demande,
               o.categorie,
               (SELECT json_agg(json_build_object('id_appareil', a.id_appareil,
                                                  'jeton', a.jeton_notification,
                                                  'environnement', a.environnement)
                                ORDER BY a.id_appareil)
                  FROM appareil a WHERE a.id_utilisateur = n.id_utilisateur) AS appareils
          FROM notification n
          JOIN utilisateur u ON u.id_utilisateur = n.id_utilisateur AND u.actif
          LEFT JOIN v_occurrence o ON o.id_occurrence = n.id_occurrence
         WHERE n.apple_statut = 'a_envoyer'
           AND (NOT en_silence(n.id_utilisateur)
                -- ACC-9 : une demande d'un client est une conversation en cours.
                OR n.type = 'demande'
                OR (n.type = 'coach'
                    AND EXISTS (SELECT 1 FROM appel_coach c
                                 WHERE c.id_utilisateur = n.id_utilisateur
                                   AND c.declencheur = 'utilisateur'
                                   AND c.debut > now() - INTERVAL '30 minutes')))
         ORDER BY n.date_creation
         LIMIT %(limite)s
        """,
        {"limite": limite},
    )


def _raison(reponse: httpx.Response) -> str:
    try:
        return str(reponse.json().get("reason") or "")
    except ValueError:
        return ""


def _envoyer_a(client: httpx.Client, appareil: dict, corps: bytes) -> str:
    """« ok », « mort » (le jeton ne sert plus), ou « reessayer »."""
    conf = configuration()
    for _ in range(2):
        try:
            reponse = client.post(
                f"{HOTES[appareil['environnement']]}/3/device/{appareil['jeton']}",
                content=corps,
                headers={
                    "authorization": f"bearer {jeton_fournisseur()}",
                    "apns-topic": conf.apns_sujet,
                    "apns-push-type": "alert",
                    "apns-priority": "10",
                    "apns-expiration": str(int(time.time()) + 86400),
                    "content-type": "application/json",
                },
            )
        except httpx.HTTPError as erreur:
            LOG.warning("Apple injoignable : %s", erreur)
            return "reessayer"

        if reponse.status_code == 200:
            return "ok"
        raison = _raison(reponse)
        if reponse.status_code == 410 or raison in JETONS_MORTS:
            return "mort"
        if reponse.status_code == 403 and raison in JETON_FOURNISSEUR_REFUSE:
            # Un jeton refait, une seconde chance.
            oublier_le_jeton()
            continue
        LOG.warning("Apple refuse la notification (%s %s)", reponse.status_code, raison)
        return "reessayer"
    return "reessayer"


def envoyer_la_file(client: httpx.Client | None = None, limite: int = 50) -> dict:
    """Un passage : range ce qui ne partira pas, puis envoie ce qui est dû."""
    _ranger()
    if not configuree():
        return {"envoyees": 0, "desactive": True}

    propre = client is None
    client = client or httpx.Client(http2=True, timeout=10)
    bilan = {"envoyees": 0, "en_attente": 0, "echecs": 0, "appareils_oublies": 0}
    try:
        for notification in a_envoyer(limite):
            corps = json.dumps(charge(notification), ensure_ascii=False).encode()
            issues = []
            for appareil in notification["appareils"] or []:
                issue = _envoyer_a(client, appareil, corps)
                issues.append(issue)
                if issue == "mort":
                    executer("DELETE FROM appareil WHERE id_appareil = %(a)s",
                             {"a": appareil["id_appareil"]})
                    bilan["appareils_oublies"] += 1

            if "ok" in issues:
                statut = "envoyee"
            elif issues and all(issue == "mort" for issue in issues):
                statut = "sans_appareil"
            elif notification["apple_essais"] + 1 >= ESSAIS_MAX:
                statut = "echec"
            else:
                statut = "a_envoyer"

            executer(
                """UPDATE notification
                      SET apple_statut = %(s)s::TEXT,
                          apple_essais = apple_essais
                                         + CASE WHEN %(s)s::TEXT = 'envoyee' THEN 0 ELSE 1 END,
                          apple_envoyee_le = CASE WHEN %(s)s::TEXT = 'envoyee' THEN now() END
                    WHERE id_notification = %(n)s""",
                {"s": statut, "n": notification["id_notification"]})
            if statut == "envoyee":
                bilan["envoyees"] += 1
            elif statut == "echec":
                bilan["echecs"] += 1
            elif statut == "a_envoyer":
                bilan["en_attente"] += 1
    finally:
        if propre:
            client.close()
    return bilan
