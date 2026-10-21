"""Les fournisseurs du modèle d'un compte                    (FOU-1 à FOU-9)

Chaque compte range ses fournisseurs : son abonnement Claude, que Claude Code
fait travailler sur le serveur, puis l'API, en secours. Un appel prend le
premier disponible ; quand il cède (limite d'usage, jeton refusé, plafond), le
suivant prend le relais dans la même opération, et le fournisseur qui a cédé
est mis de côté jusqu'à ce qu'il revienne.

Un compte sans fournisseur garde la clé d'API du serveur : rien ne change pour
lui. Les secrets sont chiffrés en base avec une clé de .env (FOU-3) ; ils ne
sortent jamais de ce module autrement que pour l'appel qui s'en sert.
"""

import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from cryptography.fernet import Fernet, InvalidToken

from api.base import executer, lister, un_seul
from api.config import configuration

LOG = logging.getLogger(__name__)

TYPES = ("claude_code", "api", "gemini_cli")

LIBELLES = {"claude_code": "Abonnement Claude (Claude Code)", "api": "API d'Anthropic",
            "gemini_cli": "Gemini CLI", "serveur": "API du serveur"}

# FOU-9 : en quelques mots, sous un message (« par l'API : abonnement épuisé »).
COURTS = {"claude_code": "abonnement", "api": "l'API", "gemini_cli": "Gemini",
          "serveur": "l'API du serveur"}

# FOU-5 : sans heure de reprise annoncée, une heure de côté.
REPRISE_PAR_DEFAUT = timedelta(hours=1)

# Un fournisseur injoignable (réseau, panne) n'est écarté que quelques minutes.
INJOIGNABLE = timedelta(minutes=5)


class ChiffrementAbsent(Exception):
    """HAL_CLE_CHIFFREMENT n'est pas réglée : aucun secret ne peut être gardé."""


class Arret(Exception):
    """L'appel s'arrête de lui-même : borne de tours ou délai dépassé (COA-7).

    Ce n'est pas la faute du fournisseur : on ne passe pas au suivant."""


class Indisponible(Exception):
    """Le fournisseur cède : on passe au suivant (FOU-4).

    `nature` : « limite » (quota de l'abonnement), « jeton » (refusé ou
    expiré), « plafond » (FOU-7), « injoignable » (panne, réseau, rien
    d'installé).
    """

    def __init__(self, nature: str, motif: str, jusqu_a: datetime | None = None):
        super().__init__(motif)
        self.nature = nature
        self.motif = motif
        self.jusqu_a = jusqu_a


@dataclass
class Fournisseur:
    id_utilisateur: int
    type: str                       # claude_code, api, gemini_cli, ou serveur
    id_fournisseur: int | None = None
    secret: str | None = None       # déchiffré ; None : la clé du serveur
    rang: int = 1
    plafond: float | None = None

    @property
    def libelle(self) -> str:
        return LIBELLES.get(self.type, self.type)

    @property
    def colonne(self) -> str:
        """Ce que l'appel et l'échange notent (FOU-9)."""
        return self.type


# ---------------------------------------------------------------------------
# Chiffrement (FOU-3)
# ---------------------------------------------------------------------------

def _fernet() -> Fernet:
    cle = configuration().hal_cle_chiffrement.strip()
    if not cle:
        raise ChiffrementAbsent("HAL_CLE_CHIFFREMENT n'est pas réglée sur le serveur")
    return Fernet(cle.encode())


def chiffrer(secret: str) -> bytes:
    return _fernet().encrypt(secret.encode("utf-8"))


def dechiffrer(donnees: bytes) -> str:
    return _fernet().decrypt(bytes(donnees)).decode("utf-8")


# ---------------------------------------------------------------------------
# La chaîne d'un compte
# ---------------------------------------------------------------------------

def _maintenant() -> datetime:
    return datetime.now(UTC)


def depense_du_mois(id_utilisateur: int) -> float:
    ligne = un_seul("SELECT depense_api_du_mois(%(u)s) AS d", {"u": id_utilisateur})
    return float((ligne or {}).get("d") or 0)


def plafond_de(ligne: dict) -> float:
    return float(ligne.get("plafond_mensuel") or configuration().plafond_api_defaut)


def premier_du_mois_suivant() -> datetime:
    from api.coach.clair import fuseau
    ici = datetime.now(fuseau())
    suivant = (ici.replace(day=28) + timedelta(days=4)).replace(
        day=1, hour=0, minute=0, second=0, microsecond=0)
    return suivant.astimezone(UTC)


def chaine(id_utilisateur: int) -> list[Fournisseur]:
    """FOU-4 : les fournisseurs à essayer, dans l'ordre, sans ceux qui sont de côté.

    Un compte qui n'a rien branché garde la clé du serveur. Un compte qui a
    tout de côté n'a rien : l'appel rend le message fixe (FOU-8).
    """
    lignes = lister(
        """SELECT id_fournisseur, type, rang, secret, etat, de_cote_jusqu_a,
                  plafond_mensuel
             FROM fournisseur_modele WHERE id_utilisateur = %(u)s ORDER BY rang""",
        {"u": id_utilisateur})
    if not lignes:
        return [Fournisseur(id_utilisateur, "serveur")]

    rendus = []
    for ligne in lignes:
        if ligne["etat"] in ("coupe", "a_reconnecter"):
            continue
        if ligne["etat"] == "de_cote":
            if ligne["de_cote_jusqu_a"] > _maintenant():
                continue
            # FOU-5 : revenu tout seul.
            executer("""UPDATE fournisseur_modele SET etat = 'actif', de_cote_jusqu_a = NULL,
                               motif = NULL
                         WHERE id_fournisseur = %(f)s AND etat = 'de_cote'""",
                     {"f": ligne["id_fournisseur"]})
        fournisseur = Fournisseur(id_utilisateur, ligne["type"], ligne["id_fournisseur"],
                                  rang=ligne["rang"])
        if ligne["type"] == "api":
            fournisseur.plafond = plafond_de(ligne)
            if depense_du_mois(id_utilisateur) >= fournisseur.plafond:
                ceder(fournisseur, Indisponible(
                    "plafond", f"Plafond de {fournisseur.plafond:.2f} $ atteint ce mois-ci",
                    premier_du_mois_suivant()))
                continue
        if ligne["secret"] is not None:
            try:
                fournisseur.secret = dechiffrer(ligne["secret"])
            except (ChiffrementAbsent, InvalidToken) as erreur:
                LOG.warning("Secret du fournisseur %s illisible : %s",
                            ligne["id_fournisseur"], erreur)
                continue
        rendus.append(fournisseur)
    return rendus


def gemini_installe() -> bool:
    """Gemini CLI est-il dans l'image ? Sans lui, on ne peut pas le brancher (FOU-17)."""
    import shutil
    return shutil.which(configuration().gemini_cli_commande) is not None


def ceder(fournisseur: Fournisseur, erreur: Indisponible) -> None:
    """FOU-5, FOU-6 : un fournisseur qui cède est mis de côté, ou à reconnecter."""
    if fournisseur.id_fournisseur is None:
        return
    if erreur.nature == "jeton":
        ligne = executer(
            """UPDATE fournisseur_modele SET etat = 'a_reconnecter', de_cote_jusqu_a = NULL,
                      motif = %(m)s
                WHERE id_fournisseur = %(f)s AND etat <> 'a_reconnecter'
            RETURNING id_utilisateur""",
            {"f": fournisseur.id_fournisseur, "m": erreur.motif[:300]})
        if ligne is not None:
            # FOU-6 : prévenu une fois, au moment où le jeton est refusé.
            executer(
                "INSERT INTO notification (id_utilisateur, type, contenu) "
                "VALUES (%(u)s, 'coach', %(c)s)",
                {"u": ligne["id_utilisateur"],
                 "c": f"{fournisseur.libelle} ne répond plus : son jeton est refusé. "
                      "Colle-en un nouveau dans Réglages, Intelligence. En attendant, "
                      "HAL passe par le fournisseur suivant."})
        return
    jusqu_a = erreur.jusqu_a or _maintenant() + (
        INJOIGNABLE if erreur.nature == "injoignable" else REPRISE_PAR_DEFAUT)
    executer(
        """UPDATE fournisseur_modele SET etat = 'de_cote', de_cote_jusqu_a = %(j)s,
                  motif = %(m)s
            WHERE id_fournisseur = %(f)s AND etat IN ('actif', 'de_cote')""",
        {"f": fournisseur.id_fournisseur, "j": jusqu_a, "m": erreur.motif[:300]})


def a_servi(fournisseur: Fournisseur) -> None:
    if fournisseur.id_fournisseur is not None:
        executer("UPDATE fournisseur_modele SET dernier_usage = now() "
                 "WHERE id_fournisseur = %(f)s", {"f": fournisseur.id_fournisseur})


# ---------------------------------------------------------------------------
# Ce que Réglages affiche et change (FOU-18, FOU-19)
# ---------------------------------------------------------------------------

def lister_pour(id_utilisateur: int) -> dict:
    lignes = lister(
        """SELECT id_fournisseur, type, rang, secret_fin, etat, de_cote_jusqu_a, motif,
                  plafond_mensuel, dernier_usage, cree_le
             FROM fournisseur_modele WHERE id_utilisateur = %(u)s ORDER BY rang""",
        {"u": id_utilisateur})
    for ligne in lignes:
        ligne["libelle"] = LIBELLES[ligne["type"]]
        if ligne["type"] == "api":
            ligne["plafond_mensuel"] = plafond_de(ligne)
    return {"fournisseurs": lignes,
            "depense_api_du_mois": depense_du_mois(id_utilisateur),
            "cle_du_serveur": not lignes,
            "gemini_installe": gemini_installe(),
            "chiffrement_regle": bool(configuration().hal_cle_chiffrement.strip())}


def fin_du_secret(secret: str) -> str:
    """Ce que Réglages montre d'un secret : ses quatre derniers caractères. Pour les
    identifiants Google de Gemini CLI, ceux du jeton qui dure (refresh_token)."""
    from api.coach.course_gemini import compte_google
    google = compte_google(secret)
    return str((google or {}).get("refresh_token") or secret)[-4:]


def brancher(id_utilisateur: int, type_: str, secret: str | None,
             plafond: float | None) -> None:
    """Garde un secret déjà essayé. Le fournisseur prend le dernier rang s'il est neuf,
    garde le sien sinon, et repart actif.

    FOU-1 : le premier fournisseur branché par un compte qui passait par la clé du
    serveur ne la lui retire pas. Elle reste derrière lui, comme fournisseur `api`
    sans secret, avec son plafond : le secours quand l'abonnement est épuisé."""
    chiffre = chiffrer(secret) if secret else None
    fin = fin_du_secret(secret) if secret else None
    garder_la_cle_du_serveur = (
        type_ != "api" and bool(configuration().anthropic_api_key)
        and un_seul("SELECT 1 AS oui FROM fournisseur_modele WHERE id_utilisateur = %(u)s",
                    {"u": id_utilisateur}) is None)
    executer(
        """INSERT INTO fournisseur_modele (id_utilisateur, type, rang, secret, secret_fin,
                                           plafond_mensuel)
           VALUES (%(u)s, %(t)s,
                   COALESCE((SELECT max(rang) FROM fournisseur_modele
                              WHERE id_utilisateur = %(u)s), 0) + 1,
                   %(s)s, %(f)s, %(p)s)
           ON CONFLICT (id_utilisateur, type) DO UPDATE
              SET secret = EXCLUDED.secret, secret_fin = EXCLUDED.secret_fin,
                  plafond_mensuel = COALESCE(EXCLUDED.plafond_mensuel,
                                             fournisseur_modele.plafond_mensuel),
                  etat = 'actif', de_cote_jusqu_a = NULL, motif = NULL""",
        {"u": id_utilisateur, "t": type_, "s": chiffre, "f": fin,
         "p": plafond if type_ == "api" else None})
    if garder_la_cle_du_serveur:
        executer(
            """INSERT INTO fournisseur_modele (id_utilisateur, type, rang)
               VALUES (%(u)s, 'api', (SELECT max(rang) FROM fournisseur_modele
                                       WHERE id_utilisateur = %(u)s) + 1)
               ON CONFLICT (id_utilisateur, type) DO NOTHING""",
            {"u": id_utilisateur})


def renouveler(fournisseur: Fournisseur, secret: str) -> None:
    """Gemini CLI a renouvelé les identifiants Google pendant la course : on garde
    les nouveaux, pour ne pas les renouveler à chaque appel."""
    if fournisseur.id_fournisseur is None:
        return
    try:
        executer("UPDATE fournisseur_modele SET secret = %(s)s WHERE id_fournisseur = %(f)s",
                 {"f": fournisseur.id_fournisseur, "s": chiffrer(secret)})
    except ChiffrementAbsent:
        LOG.warning("Identifiants renouvelés non gardés : HAL_CLE_CHIFFREMENT manque")


def regler_plafond(id_utilisateur: int, plafond: float) -> bool:
    ligne = executer(
        """UPDATE fournisseur_modele SET plafond_mensuel = %(p)s
            WHERE id_utilisateur = %(u)s AND type = 'api' RETURNING id_fournisseur""",
        {"u": id_utilisateur, "p": plafond})
    return ligne is not None


def ranger(id_utilisateur: int, ordre: list[str]) -> None:
    """Les types dans l'ordre voulu. La contrainte de rang est vérifiée en fin de
    transaction : l'échange de deux rangs passe."""
    from api.base import connexion
    with connexion() as conn, conn.cursor() as cur:
        for rang, type_ in enumerate(ordre, start=1):
            cur.execute("UPDATE fournisseur_modele SET rang = %(r)s "
                        "WHERE id_utilisateur = %(u)s AND type = %(t)s",
                        {"r": rang, "u": id_utilisateur, "t": type_})
        # Ceux qu'on n'a pas nommés gardent leur ordre, après.
        cur.execute("UPDATE fournisseur_modele SET rang = rang + 100 "
                    "WHERE id_utilisateur = %(u)s AND NOT (type = ANY (%(o)s::TEXT[]))",
                    {"u": id_utilisateur, "o": ordre})
        cur.execute("""UPDATE fournisseur_modele f SET rang = x.n
                         FROM (SELECT id_fournisseur,
                                      row_number() OVER (ORDER BY rang) AS n
                                 FROM fournisseur_modele WHERE id_utilisateur = %(u)s) x
                        WHERE f.id_fournisseur = x.id_fournisseur""",
                    {"u": id_utilisateur})


def changer_etat(id_utilisateur: int, type_: str, coupe: bool) -> bool:
    ligne = executer(
        """UPDATE fournisseur_modele
              SET etat = CASE WHEN %(c)s THEN 'coupe' ELSE 'actif' END,
                  de_cote_jusqu_a = NULL, motif = NULL
            WHERE id_utilisateur = %(u)s AND type = %(t)s
              AND (%(c)s OR etat = 'coupe')
        RETURNING id_fournisseur""",
        {"u": id_utilisateur, "t": type_, "c": coupe})
    return ligne is not None


def retirer(id_utilisateur: int, type_: str) -> bool:
    """Le secret part avec la ligne (FOU-3). Les rangs suivants se resserrent."""
    ligne = executer(
        "DELETE FROM fournisseur_modele WHERE id_utilisateur = %(u)s AND type = %(t)s "
        "RETURNING id_fournisseur", {"u": id_utilisateur, "t": type_})
    if ligne is not None:
        ranger(id_utilisateur, [])
    return ligne is not None


# ---------------------------------------------------------------------------
# Les petits travaux (FOU-15)
# ---------------------------------------------------------------------------

def ecrire(id_utilisateur: int, systeme: str, texte: str, modele_nom: str,
           max_tokens: int, delai: float, abonnement: bool = True):
    """Un appel sans outils par la chaîne du compte : les résumés de la mémoire
    (MEM-7), et le choix des paquets (DOS-4).

    Le choix des paquets doit répondre en quelques secondes, plus vite que
    Claude Code ne démarre : il passe `abonnement=False`, et ne prend que l'API.
    Un délai dépassé n'y met pas l'API de côté pour l'appel qui suit.
    """
    from api.coach import course, modele

    for fournisseur in chaine(id_utilisateur):
        if fournisseur.type == "gemini_cli" or (fournisseur.type == "claude_code"
                                                and not abonnement):
            continue
        try:
            if fournisseur.type == "claude_code":
                tour = course.ecrire(fournisseur.secret, systeme, texte, modele_nom, delai)
            else:
                avec_cle = {"cle": fournisseur.secret} if fournisseur.secret else {}
                tour = modele.ecrire(systeme, texte, modele_nom, max_tokens, delai, **avec_cle)
            a_servi(fournisseur)
            return tour
        except (Indisponible, modele.ModeleInjoignable) as erreur:
            nature = getattr(erreur, "nature", "injoignable")
            if abonnement or nature != "injoignable":
                ceder(fournisseur, erreur if isinstance(erreur, Indisponible)
                      else Indisponible(nature, str(erreur)))
            LOG.info("%s ne rédige pas (%s) : %s", fournisseur.libelle, nature, erreur)
    raise modele.ModeleInjoignable("Aucun fournisseur disponible pour rédiger")
