"""Se connecter avec Apple                                         (CNX-7 à CNX-9)

L'appli reçoit d'Apple un jeton d'identité (un JWT signé RS256) et l'envoie tel
quel. On le vérifie ici : la signature par une clé publiée par Apple, l'émetteur,
le destinataire (l'identifiant de l'appli) et l'expiration. Ce qu'il en reste,
c'est `sub`, l'identifiant stable de la personne pour cette appli, relié à un
compte dans `utilisateur.identifiant_apple`.

Les clés d'Apple changent rarement : on les garde, et on ne les redemande que
pour une clé inconnue, au plus une fois toutes les cinq minutes.
"""

from __future__ import annotations

import base64
import json
import logging
import time
from dataclasses import dataclass, field

import httpx
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from api.base import executer, un_seul
from api.config import configuration

LOG = logging.getLogger(__name__)

EMETTEUR = "https://appleid.apple.com"
URL_DES_CLES = "https://appleid.apple.com/auth/keys"
# L'horloge de l'iPhone et celle du serveur ne sont jamais tout à fait d'accord.
TOLERANCE = 60
ATTENTE_ENTRE_DEUX_TELECHARGEMENTS = 5 * 60


class JetonRefuse(Exception):
    """Le jeton ne vient pas d'Apple pour cette appli, ou il a expiré."""


def _d64(texte: str) -> bytes:
    return base64.urlsafe_b64decode(texte + "=" * (-len(texte) % 4))


@dataclass
class _Cles:
    par_kid: dict[str, rsa.RSAPublicKey] = field(default_factory=dict)
    telechargees_le: float = 0.0


_cles = _Cles()


def _telecharger_cles() -> list[dict]:
    reponse = httpx.get(URL_DES_CLES, timeout=10)
    reponse.raise_for_status()
    return reponse.json()["keys"]


def _cle(kid: str) -> rsa.RSAPublicKey:
    if kid not in _cles.par_kid and \
            time.time() - _cles.telechargees_le > ATTENTE_ENTRE_DEUX_TELECHARGEMENTS:
        try:
            publiees = _telecharger_cles()
        except (httpx.HTTPError, KeyError, ValueError) as erreur:
            LOG.warning("Clés d'Apple illisibles : %s", erreur)
            raise JetonRefuse() from erreur
        _cles.par_kid = {
            c["kid"]: rsa.RSAPublicNumbers(int.from_bytes(_d64(c["e"]), "big"),
                                           int.from_bytes(_d64(c["n"]), "big")).public_key()
            for c in publiees if c.get("kty") == "RSA"}
        _cles.telechargees_le = time.time()
    if kid not in _cles.par_kid:
        raise JetonRefuse()
    return _cles.par_kid[kid]


def oublier_les_cles() -> None:
    _cles.par_kid, _cles.telechargees_le = {}, 0.0


def verifier(jeton: str, maintenant: float | None = None) -> str:
    """CNX-7 : rend l'identifiant Apple que porte le jeton, ou lève JetonRefuse."""
    try:
        entete_b64, corps_b64, signature_b64 = jeton.strip().split(".")
        entete = json.loads(_d64(entete_b64))
        corps = json.loads(_d64(corps_b64))
        signature = _d64(signature_b64)
    except ValueError as erreur:
        raise JetonRefuse() from erreur
    if entete.get("alg") != "RS256":
        raise JetonRefuse()

    try:
        _cle(str(entete.get("kid"))).verify(signature, f"{entete_b64}.{corps_b64}".encode(),
                                            padding.PKCS1v15(), hashes.SHA256())
    except InvalidSignature as erreur:
        raise JetonRefuse() from erreur

    instant = maintenant if maintenant is not None else time.time()
    if corps.get("iss") != EMETTEUR:
        raise JetonRefuse()
    # Le destinataire est l'identifiant de l'appli, le même que le sujet des
    # notifications d'Apple.
    if corps.get("aud") != configuration().apns_sujet:
        raise JetonRefuse()
    if not isinstance(corps.get("exp"), (int, float)) or corps["exp"] + TOLERANCE < instant:
        raise JetonRefuse()
    sub = corps.get("sub")
    if not isinstance(sub, str) or not sub:
        raise JetonRefuse()
    return sub


def compte(identifiant: str) -> dict | None:
    """CNX-7 : le compte actif relié à cet identifiant Apple."""
    return un_seul("""SELECT id_utilisateur, pseudo FROM utilisateur
                       WHERE identifiant_apple = %(i)s AND actif""", {"i": identifiant})


def relier(id_utilisateur: int, identifiant: str) -> None:
    """CNX-8 : relie l'identifiant à ce compte. Relié avant à un autre compte, il
    le quitte : on vient de prouver qu'on tient celui-ci."""
    executer("""UPDATE utilisateur SET identifiant_apple = NULL
                 WHERE identifiant_apple = %(i)s AND id_utilisateur <> %(u)s""",
             {"i": identifiant, "u": id_utilisateur})
    executer("UPDATE utilisateur SET identifiant_apple = %(i)s WHERE id_utilisateur = %(u)s",
             {"i": identifiant, "u": id_utilisateur})


def delier(id_utilisateur: int) -> None:
    executer("UPDATE utilisateur SET identifiant_apple = NULL WHERE id_utilisateur = %(u)s",
             {"u": id_utilisateur})


def relie(id_utilisateur: int) -> bool:
    ligne = un_seul("SELECT identifiant_apple IS NOT NULL AS relie FROM utilisateur "
                    "WHERE id_utilisateur = %(u)s", {"u": id_utilisateur})
    return bool(ligne and ligne["relie"])
