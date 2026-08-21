"""Lecture des confirmations d'achat SNCF.

Acheter un billet est déjà une déclaration d'absence. La refaire à la main dans
le bot est du travail en double, et le travail en double finit par ne plus être
fait — d'où ce module.

Deux précautions le structurent.

La première est une question de sécurité. Les faux courriels SNCF sont
répandus, et un mail non vérifié pourrait geler deux jours de ménage, ou pire
si l'analyse servait un jour à autre chose. Seuls les expéditeurs officiels
sont analysés, et la liste est fermée (R73).

La seconde est une question d'honnêteté. Le format de ces courriels n'est pas
un contrat : il change quand la SNCF le décide. L'analyse est donc tolérante,
et surtout, ce qu'elle ne sait pas lire est conservé avec son motif plutôt que
jeté (R75). C'est la seule façon de corriger le lecteur.

IMAP et analyse sont séparés : les tests rejouent des courriels enregistrés,
sans jamais ouvrir de connexion.
"""

from __future__ import annotations

import email
import email.policy
import html
import imaplib
import logging
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from email.message import EmailMessage
from zoneinfo import ZoneInfo

from api.config import configuration

LOG = logging.getLogger(__name__)

# R73 : les domaines réellement utilisés par SNCF Connect. Tout le reste est
# ignoré sans être analysé — c'est une liste blanche, pas un filtre anti-spam.
EXPEDITEURS = (
    "mail.sncf-connect.com",
    "mail.sncfconnect.com",
    "info.sncf.com",
    "connect.sncf",
    "sncf-connect.com",
)

# Gares reconnues, avec leurs orthographes courantes. L'annuaire complet n'a
# aucun intérêt ici : deux gares suffisent, et une gare inconnue doit rendre le
# courriel illisible plutôt que d'être devinée.
VARIANTES = {
    "NANCY": ("nancy ville", "nancy-ville", "nancy"),
    "SAINT_DIE": (
        "saint die des vosges", "saint-die-des-vosges", "st die des vosges",
        "st-die-des-vosges", "saint die", "st die",
    ),
}

MOIS = {
    "janvier": 1, "fevrier": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6,
    "juillet": 7, "aout": 8, "septembre": 9, "octobre": 10, "novembre": 11,
    "decembre": 12,
}

_MOTIF_GARE = "|".join(
    re.escape(v) for v in sorted(
        (v for variantes in VARIANTES.values() for v in variantes),
        key=len, reverse=True,
    )
)
GARE = re.compile(_MOTIF_GARE)
HEURE = re.compile(r"\b(\d{1,2})\s*[h:]\s*(\d{2})\b")
DATE_LONGUE = re.compile(
    r"\b(\d{1,2})\s+(" + "|".join(MOIS) + r")\s+(\d{4})\b")
DATE_COURTE = re.compile(r"\b(\d{1,2})/(\d{1,2})/(\d{4})\b")
# Le mot-clé se lit sans égard à la casse ni aux accents, mais la référence
# elle-même est en capitales : la chercher en minuscules attraperait n'importe
# quel mot de six lettres.
REFERENCE = re.compile(
    r"(?i:dossier|r[ée]f[ée]rence|r[ée]servation)\D{0,30}?\b([A-Z]{6})\b")

# « durée 1h35 » n'est pas un horaire. Sans cette exclusion, la durée du trajet
# se glisserait dans la suite des heures et décalerait tout.
AVANT_DUREE = re.compile(r"(dur[ée]e?|trajet\s+de|environ)\W{0,12}$")


@dataclass(frozen=True)
class Segment:
    depart_gare: str
    arrivee_gare: str
    depart: datetime
    arrivee: datetime

    @property
    def sens(self) -> str:
        return "aller" if self.depart_gare == configuration().gare_domicile else "retour"


@dataclass
class Lecture:
    """Ce qu'on a compris d'un courriel, y compris quand ce n'est rien."""

    identifiant: str
    expediteur: str
    sujet: str
    recu_le: datetime | None = None
    reference: str | None = None
    segments: list[Segment] = field(default_factory=list)
    statut: str = "ignore"
    motif: str | None = None


def _sans_accent(texte: str) -> str:
    decompose = unicodedata.normalize("NFD", texte)
    return "".join(c for c in decompose if unicodedata.category(c) != "Mn")


def normaliser(texte: str) -> str:
    """Minuscules, sans accent, espaces resserrés. Les tirets deviennent des espaces.

    Les courriels mélangent « Saint-Dié-des-Vosges », « ST DIE DES VOSGES » et
    « Saint Dié ». Comparer sans normaliser reviendrait à écrire une variante
    par service marketing.
    """
    texte = _sans_accent(texte).lower()
    texte = texte.replace(" ", " ").replace("’", "'")
    texte = re.sub(r"[‐-―-]", " ", texte)
    return re.sub(r"[ \t]+", " ", texte)


def _gare_de(mot: str) -> str | None:
    for code, variantes in VARIANTES.items():
        if mot in variantes:
            return code
    return None


def texte_de(message: EmailMessage) -> str:
    """Corps du message en texte, que l'expéditeur ait envoyé du texte ou du HTML."""
    corps = message.get_body(preferencelist=("plain", "html"))
    if corps is None:
        return ""

    contenu = corps.get_content()
    if corps.get_content_subtype() == "html":
        contenu = re.sub(r"(?is)<(script|style).*?</\1>", " ", contenu)
        # Les sauts de ligne portent du sens : une gare et son heure sont sur
        # la même ligne, l'arrivée sur la suivante.
        contenu = re.sub(r"(?i)<(br|/p|/div|/tr|/td)[^>]*>", "\n", contenu)
        contenu = re.sub(r"<[^>]+>", " ", contenu)
        contenu = html.unescape(contenu)

    return contenu


def _jetons(texte: str) -> list[tuple[int, str, object]]:
    """Suite ordonnée des dates, gares et heures rencontrées.

    Travailler sur un flux de jetons plutôt que ligne par ligne : la même
    information s'écrit sur une ligne dans un courriel en texte et sur quatre
    dans sa version HTML, et on ne veut pas deux analyses.
    """
    jetons: list[tuple[int, str, object]] = []

    for m in DATE_LONGUE.finditer(texte):
        jetons.append((m.start(), "date",
                       (int(m.group(1)), MOIS[m.group(2)], int(m.group(3)))))
    for m in DATE_COURTE.finditer(texte):
        jetons.append((m.start(), "date",
                       (int(m.group(1)), int(m.group(2)), int(m.group(3)))))

    for m in GARE.finditer(texte):
        gare = _gare_de(m.group(0))
        if gare is not None:
            jetons.append((m.start(), "gare", gare))

    for m in HEURE.finditer(texte):
        if AVANT_DUREE.search(texte[max(0, m.start() - 24):m.start()]):
            continue
        heures, minutes = int(m.group(1)), int(m.group(2))
        if heures > 23 or minutes > 59:
            continue
        jetons.append((m.start(), "heure", (heures, minutes)))

    jetons.sort(key=lambda j: j[0])

    # Une gare citée deux fois de suite — « Nancy Ville » suivi de « Nancy » —
    # ne fait qu'une gare. Sans ce repli, l'appariement se décalerait.
    resserres: list[tuple[int, str, object]] = []
    for jeton in jetons:
        if resserres and jeton[1] == "gare" == resserres[-1][1] \
                and jeton[2] == resserres[-1][2]:
            continue
        resserres.append(jeton)
    return resserres


def segments_de(texte: str) -> list[Segment]:
    """Apparie les jetons en trajets : une gare, une heure, une gare, une heure.

    Le motif est celui de tous les récapitulatifs de voyage, quelle que soit la
    mise en page. Ce qui ne le suit pas n'est pas deviné : mieux vaut un
    courriel signalé illisible qu'une absence inventée.
    """
    texte = normaliser(texte)
    jetons = _jetons(texte)
    fuseau = ZoneInfo(configuration().fuseau)

    segments: list[Segment] = []
    date_courante: tuple[int, int, int] | None = None
    tampon: list[tuple[str, object]] = []

    def vider() -> None:
        tampon.clear()

    for _, genre, valeur in jetons:
        if genre == "date":
            date_courante = valeur  # type: ignore[assignment]
            vider()
            continue

        if date_courante is None:
            continue

        attendu = ("gare", "heure", "gare", "heure")[len(tampon)]
        if genre != attendu:
            # Un jeton hors motif casse la série en cours plutôt que de
            # décaler l'appariement sur tout le reste du courriel.
            vider()
            if genre == "gare":
                tampon.append((genre, valeur))
            continue

        tampon.append((genre, valeur))
        if len(tampon) < 4:
            continue

        jour, mois, annee = date_courante
        depart_h, depart_m = tampon[1][1]  # type: ignore[misc]
        arrivee_h, arrivee_m = tampon[3][1]  # type: ignore[misc]

        depart = datetime(annee, mois, jour, depart_h, depart_m, tzinfo=fuseau)
        arrivee = datetime(annee, mois, jour, arrivee_h, arrivee_m, tzinfo=fuseau)
        # Un train de 23h10 qui arrive à 00h45 arrive le lendemain.
        if arrivee < depart:
            arrivee += timedelta(days=1)

        depart_gare, arrivee_gare = tampon[0][1], tampon[2][1]
        if depart_gare != arrivee_gare:
            segments.append(Segment(
                depart_gare=str(depart_gare), arrivee_gare=str(arrivee_gare),
                depart=depart, arrivee=arrivee,
            ))
        vider()

    return segments


def expediteur_reconnu(adresse: str) -> bool:
    adresse = adresse.lower()
    domaine = adresse.rpartition("@")[2].strip(" >")
    return any(domaine == d or domaine.endswith("." + d) for d in EXPEDITEURS)


def analyser(brut: bytes) -> Lecture:
    """Lit un courriel entier, et dit ce qu'il en a compris.

    Ne lève jamais : un courriel mal formé est un résultat, pas un incident.
    Le relevé tourne sans surveillance, et une exception y ferait perdre les
    courriels suivants.
    """
    message = email.message_from_bytes(brut, policy=email.policy.default)

    identifiant = str(message.get("Message-ID") or "").strip()
    expediteur = str(message.get("From") or "")
    sujet = str(message.get("Subject") or "")
    recu_le = None
    try:
        recu_le = email.utils.parsedate_to_datetime(message.get("Date"))
    except (TypeError, ValueError):
        pass

    lecture = Lecture(
        identifiant=identifiant or f"sans-id-{hash(brut)}",
        expediteur=expediteur, sujet=sujet, recu_le=recu_le,
    )

    if not expediteur_reconnu(expediteur):
        lecture.statut = "ignore"
        lecture.motif = "Expéditeur non reconnu"
        return lecture

    try:
        texte = texte_de(message)
    except Exception as erreur:  # noqa: BLE001 - un corps illisible est un cas, pas un bug
        lecture.statut = "illisible"
        lecture.motif = f"Corps illisible : {erreur}"
        return lecture

    normalise = normaliser(texte)
    reference = REFERENCE.search(texte)
    lecture.reference = reference.group(1) if reference else None

    lecture.segments = segments_de(texte)
    if not lecture.segments:
        connu = any(mot in normalise for mot in ("billet", "voyage", "commande"))
        lecture.statut = "illisible" if connu else "ignore"
        lecture.motif = (
            "Aucun trajet reconnu entre les gares connues"
            if connu else "Courriel sans billet"
        )
        return lecture

    lecture.statut = "traite"
    return lecture


# ---------------------------------------------------------------------------
# Boîte aux lettres
# ---------------------------------------------------------------------------

class BoiteIndisponible(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def nom_de_dossier(dossier: str) -> str:
    """Nom de dossier tel qu'IMAP l'attend, guillemets compris.

    Un libellé Gmail est un dossier IMAP, et un libellé s'appelle volontiers
    « Billets SNCF ». Sans guillemets, l'espace coupe la commande en deux et le
    serveur répond qu'il ne connaît pas « Billets ».
    """
    dossier = dossier.strip()
    if dossier.startswith('"') and dossier.endswith('"'):
        return dossier
    return f'"{dossier}"'


def criteres_recherche(depuis: datetime, filtre_expediteur: str = "") -> tuple[str, ...]:
    """Critères passés au serveur, plutôt que de trier après coup.

    Le filtre sur l'expéditeur compte surtout quand on lit directement la boîte
    de réception : rapatrier plusieurs milliers de courriels pour en analyser
    trois serait long et sans objet. Il ne remplace pas la liste blanche, qui
    reste seule juge de ce qu'on accepte (R73) — un serveur qui filtrerait mal
    ne doit pas pouvoir faire entrer un courriel non vérifié.
    """
    criteres: list[str] = ["SINCE", depuis.strftime("%d-%b-%Y")]
    if filtre_expediteur:
        criteres += ["FROM", filtre_expediteur]
    return tuple(criteres)


def _selectionner(boite: imaplib.IMAP4_SSL, dossier: str) -> None:
    """Ouvre le dossier en lecture seule, et dit lesquels existent en cas d'échec.

    Lecture seule : lire la boîte ne doit pas marquer les courriels comme lus.
    Un système qui fait disparaître le gras des messages non lus dans le dos de
    son propriétaire ne se fait pardonner qu'une fois.
    """
    statut, _ = boite.select(nom_de_dossier(dossier), readonly=True)
    if statut == "OK":
        return

    statut, brut = boite.list()
    connus = []
    for ligne in brut or []:
        texte = ligne.decode(errors="replace") if isinstance(ligne, bytes) else str(ligne)
        nom = texte.rsplit(' "/" ', 1)[-1].strip().strip('"')
        if nom and not nom.startswith("[Gmail]"):
            connus.append(nom)

    raise BoiteIndisponible(
        "dossier_inconnu",
        f"Le dossier « {dossier} » n'existe pas. "
        f"Dossiers disponibles : {', '.join(connus) or 'aucun'}.",
    )


def relever_imap(depuis_jours: int | None = None) -> list[bytes]:
    """Récupère les courriels récents. C'est la seule fonction qui parle au réseau."""
    conf = configuration()
    if not (conf.imap_hote and conf.imap_utilisateur and conf.imap_mot_de_passe):
        raise BoiteIndisponible(
            "boite_absente",
            "Pas de boîte configurée. Renseigner IMAP_HOTE, IMAP_UTILISATEUR "
            "et IMAP_MOT_DE_PASSE dans le .env.",
        )

    depuis = datetime.now(ZoneInfo(conf.fuseau)) - timedelta(
        days=depuis_jours or conf.imap_depuis_jours)

    try:
        with imaplib.IMAP4_SSL(conf.imap_hote, conf.imap_port) as boite:
            boite.login(conf.imap_utilisateur, conf.imap_mot_de_passe)
            _selectionner(boite, conf.imap_dossier)

            statut, reponse = boite.search(
                None, *criteres_recherche(depuis, conf.imap_filtre_expediteur))
            if statut != "OK":
                raise BoiteIndisponible("recherche_refusee",
                                        "La boîte a refusé la recherche")

            messages = []
            for numero in (reponse[0] or b"").split():
                statut, donnees = boite.fetch(numero, "(BODY.PEEK[])")
                if statut == "OK" and donnees and isinstance(donnees[0], tuple):
                    messages.append(donnees[0][1])
            return messages

    except imaplib.IMAP4.error as erreur:
        raise BoiteIndisponible("connexion_refusee",
                                f"Boîte injoignable : {erreur}") from erreur
    except OSError as erreur:
        raise BoiteIndisponible("injoignable",
                                f"Boîte injoignable : {erreur}") from erreur
