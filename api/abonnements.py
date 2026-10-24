"""Les adresses d'abonnement au planning                          (NOT-5 à NOT-9)

Le flux iCalendar d'un compte, les calendriers composés qu'on se fait, et
l'adresse à donner à l'application Calendrier du téléphone. Le flux lui-même
s'écrit dans api/calendrier.py.
"""

from __future__ import annotations

from api.base import lister, un_seul
from api.config import configuration


def url_calendrier(id_utilisateur: int, defaut: str | None = None) -> dict | None:
    """URL d'abonnement au flux iCalendar, ou None si l'hôte est inconnu.

    `HOTE_PUBLIC` l'emporte sur `defaut`, qui n'est qu'un repli tiré de la
    requête : interrogée depuis le Mac, l'API renverrait sinon « localhost ».

    Le lien `webcal://` n'accompagne l'adresse que sur un flux en clair : iOS
    le traduit en `http://` et jamais en `https://`.

    Le protocole se déduit de l'hôte. Sans port, ou sur l'un des ports que
    Tailscale réserve à ses tunnels chiffrés, c'est du HTTPS ; sur tout autre
    port, c'est un serveur local en clair.

    Le lien était auparavant toujours en `http://`, ce qui marchait sur le Mac
    — le navigateur corrigeait — et échouait sur le téléphone, l'application
    Calendrier ne corrigeant rien.
    """
    ligne = un_seul(
        "SELECT jeton_calendrier FROM utilisateur WHERE id_utilisateur = %(u)s AND actif",
        {"u": id_utilisateur},
    )
    if ligne is None:
        return None

    return url_abonnement(ligne["jeton_calendrier"], defaut)


def url_abonnement(jeton: str, defaut: str | None = None) -> dict | None:
    """Même adresse pour un compte et pour un calendrier composé : seul le
    jeton change (NOT-8)."""
    hote = (configuration().hote_public or defaut or "").strip().rstrip("/")
    if not hote:
        return None
    hote = hote.split("://", 1)[-1]

    # 443, 8443 et 10000 sont les seuls ports que Tailscale accepte pour un
    # tunnel public : sur ceux-là, la connexion est chiffrée de bout en bout.
    PORTS_CHIFFRES = {"443", "8443", "10000"}
    port = hote.rpartition(":")[2] if ":" in hote else ""
    protocole = "http" if port.isdigit() and port not in PORTS_CHIFFRES else "https"

    chemin = f"{hote}/planning.ics?cle={jeton}"

    # iOS traduit « webcal:// » en « http:// » et jamais en « https:// ». Sur
    # un flux chiffré, le téléphone part donc en clair, signale l'absence de
    # SSL, et l'abonnement échoue ; la variante « webcals:// » n'est pas
    # reconnue. Le lien webcal n'est proposé que sur un flux en clair.
    webcal = f"webcal://{chemin}" if protocole == "http" else None

    return {"url": f"{protocole}://{chemin}",
            "webcal": webcal,
            "hote": hote,
            "protocole": protocole}


def calendriers_de(id_utilisateur: int) -> list[dict]:
    """Les calendriers composés qu'on a créés, avec de quoi les afficher."""
    return lister(
        """
        SELECT c.id_calendrier, c.libelle, c.jeton, c.personnes, c.contenus,
               (SELECT array_agg(u.nom ORDER BY u.nom)
                  FROM utilisateur u
                 WHERE u.id_utilisateur = ANY (c.personnes)) AS noms
          FROM calendrier c
         WHERE c.id_proprietaire = %(u)s
         ORDER BY c.libelle
        """,
        {"u": id_utilisateur},
    )


def creer_calendrier(id_utilisateur: int, libelle: str,
                     personnes: list[int], contenus: list[str]) -> dict | None:
    return un_seul(
        "SELECT * FROM creer_calendrier(%(u)s, %(libelle)s, %(personnes)s, %(contenus)s)",
        {"u": id_utilisateur, "libelle": libelle,
         "personnes": list(personnes), "contenus": list(contenus)},
    )


def supprimer_calendrier(id_utilisateur: int, id_calendrier: int) -> bool:
    ligne = un_seul(
        "SELECT supprimer_calendrier(%(u)s, %(c)s) AS parti",
        {"u": id_utilisateur, "c": id_calendrier},
    )
    return bool(ligne and ligne["parti"])


def renouveler_calendrier(id_utilisateur: int) -> str | None:
    """Invalide l'abonnement en place et en rend un nouveau."""
    ligne = un_seul(
        "SELECT renouveler_jeton_calendrier(%(u)s) AS jeton", {"u": id_utilisateur}
    )
    return ligne["jeton"] if ligne else None


def comptes_actifs() -> list[dict]:
    return lister(
        "SELECT id_utilisateur, pseudo, nom FROM utilisateur "
        " WHERE actif ORDER BY id_utilisateur"
    )
