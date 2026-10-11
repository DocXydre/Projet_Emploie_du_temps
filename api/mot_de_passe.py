"""Le mot de passe d'un compte                                   (CNX-1 à CNX-4)

Il ne sert qu'à une chose : rendre la clé d'API à l'appli, qui la garde ensuite
dans le trousseau de l'iPhone. Il n'est jamais stocké, seulement son empreinte
scrypt, et la comparaison se fait en temps constant.
"""

import hashlib
import hmac
import secrets
from datetime import timedelta

from api.base import executer, un_seul

LONGUEUR_MINIMALE = 10
ECHECS_AVANT_BLOCAGE = 5
BLOCAGE = timedelta(minutes=15)

# scrypt : 16 Mo de mémoire par essai, environ 50 ms. Assez pour décourager un
# essai en masse sur une empreinte volée, assez peu pour un petit serveur.
_N, _R, _P = 2**14, 8, 1


class MotDePasseRefuse(Exception):
    """Le mot de passe choisi ne convient pas : le motif se lit tel quel."""


def empreinte(mot_de_passe: str) -> str:
    sel = secrets.token_bytes(16)
    calcul = hashlib.scrypt(mot_de_passe.encode(), salt=sel, n=_N, r=_R, p=_P, dklen=32)
    return f"scrypt${_N}${_R}${_P}${sel.hex()}${calcul.hex()}"


def verifier(mot_de_passe: str, attendu: str | None) -> bool:
    if not attendu:
        # Même travail qu'une vraie vérification : la durée ne dit pas si le
        # compte a un mot de passe.
        empreinte(mot_de_passe)
        return False
    try:
        _, n, r, p, sel, calcul = attendu.split("$")
        essai = hashlib.scrypt(mot_de_passe.encode(), salt=bytes.fromhex(sel), n=int(n),
                               r=int(r), p=int(p), dklen=len(bytes.fromhex(calcul)))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(essai.hex(), calcul)


def choisir(id_utilisateur: int, mot_de_passe: str) -> None:
    """CNX-2 : enregistre un nouveau mot de passe, et débloque le compte."""
    if len(mot_de_passe) < LONGUEUR_MINIMALE:
        raise MotDePasseRefuse(f"Au moins {LONGUEUR_MINIMALE} caractères.")
    if mot_de_passe.strip() != mot_de_passe or not mot_de_passe.strip():
        raise MotDePasseRefuse("Pas d'espace au début ni à la fin.")
    executer("""UPDATE utilisateur SET mot_de_passe = %(m)s, echecs_connexion = 0,
                       bloque_jusqu_a = NULL
                 WHERE id_utilisateur = %(u)s""",
             {"m": empreinte(mot_de_passe), "u": id_utilisateur})


class CompteBloque(Exception):
    """CNX-3 : trop d'échecs, plus d'essai accepté pour l'instant."""


def connecter(pseudo: str, mot_de_passe: str) -> dict | None:
    """CNX-3 : rend le compte et sa clé, ou None. Un compte bloqué refuse tout,
    même le bon mot de passe, jusqu'à la fin du blocage (CompteBloque). Un pseudo
    inconnu et un mauvais mot de passe ne se distinguent pas."""
    compte = un_seul(
        """SELECT id_utilisateur, pseudo, cle_api, mot_de_passe,
                  bloque_jusqu_a > now() AS bloque
             FROM utilisateur WHERE lower(pseudo) = lower(%(p)s) AND actif""",
        {"p": (pseudo or "").strip()})
    if compte is None:
        verifier(mot_de_passe, None)
        return None
    if compte["bloque"]:
        raise CompteBloque()
    if not verifier(mot_de_passe, compte["mot_de_passe"]):
        executer(
            """UPDATE utilisateur
                  SET echecs_connexion = echecs_connexion + 1,
                      bloque_jusqu_a = CASE WHEN echecs_connexion + 1 >= %(max)s
                                            THEN now() + %(duree)s END
                WHERE id_utilisateur = %(u)s""",
            {"u": compte["id_utilisateur"], "max": ECHECS_AVANT_BLOCAGE, "duree": BLOCAGE})
        return None
    executer("UPDATE utilisateur SET echecs_connexion = 0, bloque_jusqu_a = NULL "
             "WHERE id_utilisateur = %(u)s", {"u": compte["id_utilisateur"]})
    return {"pseudo": compte["pseudo"], "cle_api": compte["cle_api"]}
