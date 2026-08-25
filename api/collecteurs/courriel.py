"""Lecture des confirmations d'achat SNCF.

Le module lit la boîte aux lettres, repère les courriels de billets et en
extrait les trajets (gares, date, horaires).

Seuls les expéditeurs de la liste blanche sont analysés (BIL-2). Un courriel
qu'on ne sait pas lire est conservé avec son motif (BIL-8).

La partie IMAP et la partie analyse sont séparées, ce qui permet aux tests de
rejouer des courriels enregistrés sans réseau.
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

# BIL-2 : liste blanche des domaines de SNCF Connect. Un courriel venant d'un
# autre domaine est ignoré sans être analysé.
EXPEDITEURS = (
    "mail.sncf-connect.com",
    "mail.sncfconnect.com",
    "info.sncf.com",
    "connect.sncf",
    "sncf-connect.com",
)

# Gares reconnues et leurs orthographes courantes. Une gare absente de cette
# table rend le courriel illisible.
VARIANTES = {
    "NANCY": ("nancy ville", "nancy-ville", "nancy"),
    "SAINT_DIE": (
        "saint die des vosges", "saint-die-des-vosges", "st die des vosges",
        "st-die-des-vosges", "saint die", "st die",
    ),
    # Lunéville est sur la ligne et sert parfois de gare de départ.
    "LUNEVILLE": ("luneville", "lunéville"),
}

NOMS_LISIBLES = {
    "NANCY": "Nancy-Ville",
    "SAINT_DIE": "Saint-Dié-des-Vosges",
    "LUNEVILLE": "Lunéville",
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
# Le mot-clé est cherché sans tenir compte de la casse ni des accents. La
# référence, elle, est en capitales : six lettres majuscules.
REFERENCE = re.compile(
    r"(?i:dossier|r[ée]f[ée]rence|r[ée]servation)\D{0,30}?\b([A-Z]{6})\b")

# Le sujet d'une confirmation contient toujours le mot « voyage ». C'est le
# seul repère stable : le reste de la phrase change d'une année sur l'autre.
MOT_VOYAGE = re.compile(r"\bvoyage\b")

# Exclut les durées (« durée 1h35 »), qui ne sont pas des horaires.
AVANT_DUREE = re.compile(r"(dur[ée]e?|trajet\s+de|environ)\W{0,12}$")


@dataclass(frozen=True)
class Segment:
    depart_gare: str
    arrivee_gare: str
    depart: datetime
    arrivee: datetime
    # Vrai quand le trajet vient du sujet : on a le jour, pas l'heure.
    sans_horaire: bool = False

    @property
    def sens(self) -> str:
        """Aller ou retour, selon la gare d'arrivée.

        On regarde la gare d'arrivée et non celle de départ, car le départ se
        fait tantôt de Nancy, tantôt de Lunéville. Arriver à la gare famille
        est un aller, en repartir est un retour.
        """
        famille = configuration().gare_famille
        return "aller" if self.arrivee_gare == famille else "retour"


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
    """Minuscules, sans accent, espaces resserrés, tirets remplacés par des espaces.

    Les courriels écrivent « Saint-Dié-des-Vosges », « ST DIE DES VOSGES » ou
    « Saint Dié ». Après normalisation, les trois se comparent.
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
        # Les balises de fin de bloc deviennent des sauts de ligne : une gare
        # et son heure sont sur la même ligne, l'arrivée sur la suivante.
        contenu = re.sub(r"(?i)<(br|/p|/div|/tr|/td)[^>]*>", "\n", contenu)
        contenu = re.sub(r"<[^>]+>", " ", contenu)
        contenu = html.unescape(contenu)

    return contenu


def _jetons(texte: str) -> list[tuple[int, str, object]]:
    """Suite ordonnée des dates, gares et heures rencontrées dans le texte.

    On travaille sur ces jetons et non ligne par ligne, car la même information
    tient sur une ligne en texte brut et sur quatre en HTML.
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

    # « Nancy Ville » suivi de « Nancy » ne compte que pour une gare : on
    # supprime les répétitions consécutives.
    resserres: list[tuple[int, str, object]] = []
    for jeton in jetons:
        if resserres and jeton[1] == "gare" == resserres[-1][1] \
                and jeton[2] == resserres[-1][2]:
            continue
        resserres.append(jeton)
    return resserres


def segments_de(texte: str) -> list[Segment]:
    """Apparie les jetons en trajets : une gare, une heure, une gare, une heure.

    C'est le motif des récapitulatifs de voyage. Ce qui ne le suit pas est
    ignoré, et le courriel ressort illisible.
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
            # Un jeton hors motif remet la série à zéro.
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


def segment_du_sujet(sujet: str) -> Segment | None:
    """Trajet lu dans le sujet, quand le corps n'en porte aucun.        (BIL-3)

    « Votre voyage St Die Des Vosges - Nancy, aller le dimanche 6 février 2022 »
    donne les deux gares, le sens et la date ; le corps ne contient que
    l'horodatage du paiement.

    Comme on n'a pas les horaires, le segment couvre la journée entière. On
    repère les gares et non une tournure de phrase, qui change chaque année.
    """
    texte = normaliser(sujet)
    if not MOT_VOYAGE.search(texte):
        return None

    gares: list[str] = []
    for trouve in GARE.finditer(texte):
        gare = _gare_de(trouve.group(0))
        if gare is not None and (not gares or gares[-1] != gare):
            gares.append(gare)

    if len(gares) < 2 or gares[0] == gares[1]:
        return None

    longue = DATE_LONGUE.search(texte)
    if longue is not None:
        jour, mois, annee = (int(longue.group(1)), MOIS[longue.group(2)],
                             int(longue.group(3)))
    else:
        courte = DATE_COURTE.search(texte)
        if courte is None:
            return None
        jour, mois, annee = (int(courte.group(1)), int(courte.group(2)),
                             int(courte.group(3)))

    fuseau = ZoneInfo(configuration().fuseau)
    minuit = datetime(annee, mois, jour, tzinfo=fuseau)

    return Segment(depart_gare=gares[0], arrivee_gare=gares[1],
                   depart=minuit, arrivee=minuit + timedelta(days=1),
                   sans_horaire=True)


def _pourquoi_rien(normalise: str) -> str:
    """Message d'échec qui compte ce qui a été trouvé : gares, heures, dates.

    Plus utile qu'un simple « aucun trajet reconnu » pour comprendre d'où vient
    le problème.
    """
    gares = sorted({g for m in GARE.finditer(normalise)
                    if (g := _gare_de(m.group(0))) is not None})
    heures = len(HEURE.findall(normalise))
    dates = len(DATE_LONGUE.findall(normalise)) + len(DATE_COURTE.findall(normalise))

    return (f"Aucun trajet reconnu — gares connues vues : "
            f"{', '.join(gares) or 'aucune'} ; heures : {heures} ; dates : {dates}")


def expediteur_reconnu(adresse: str) -> bool:
    adresse = adresse.lower()
    domaine = adresse.rpartition("@")[2].strip(" >")
    return any(domaine == d or domaine.endswith("." + d) for d in EXPEDITEURS)


def analyser(brut: bytes) -> Lecture:
    """Lit un courriel entier et renvoie ce qui en a été compris.

    Ne lève jamais d'exception : un courriel mal formé ressort avec le statut
    « illisible » et son motif, et la relève continue avec les suivants.
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
        # BIL-3 : le corps de ces confirmations ne porte que l'horodatage du
        # paiement — le récapitulatif part en pièce jointe. Le sujet, lui,
        # nomme les deux gares, le sens et la date.
        depuis_sujet = segment_du_sujet(sujet)
        if depuis_sujet is not None:
            lecture.segments = [depuis_sujet]

    if not lecture.segments:
        # C'est la présence d'une gare qui distingue un billet d'un abonnement
        # ou d'un reçu. Sans gare, le courriel est simplement ignoré ; avec une
        # gare mais sans trajet lisible, il est signalé à revoir (BIL-8).
        gares = GARE.search(normalise) or GARE.search(normaliser(sujet))
        lecture.statut = "illisible" if gares else "ignore"
        lecture.motif = (
            _pourquoi_rien(normalise) if gares
            else "Commande sans trajet : abonnement, carte ou reçu"
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
    """Entoure le nom de dossier de guillemets, comme IMAP l'attend.

    Un libellé Gmail est un dossier IMAP et peut contenir un espace
    (« Billets SNCF ») : sans guillemets, la commande est coupée en deux.
    """
    dossier = dossier.strip()
    if dossier.startswith('"') and dossier.endswith('"'):
        return dossier
    return f'"{dossier}"'


def criteres_recherche(depuis: datetime, filtre_expediteur: str = "") -> tuple[str, ...]:
    """Critères de recherche envoyés au serveur IMAP : date et expéditeur.

    Filtrer côté serveur évite de télécharger toute la boîte de réception. La
    liste blanche est vérifiée ensuite de toute façon (BIL-2).
    """
    criteres: list[str] = ["SINCE", depuis.strftime("%d-%b-%Y")]
    if filtre_expediteur:
        criteres += ["FROM", filtre_expediteur]
    return tuple(criteres)


def _selectionner(boite: imaplib.IMAP4_SSL, dossier: str) -> None:
    """Ouvre le dossier en lecture seule.

    Le mode lecture seule évite de marquer les courriels comme lus. Si le
    dossier n'existe pas, l'erreur liste ceux qui existent.
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


def identifiant_de(entete: bytes) -> str:
    """Message-ID lu dans un en-tête seul, sans avoir rapatrié le corps."""
    trouve = re.search(rb"(?im)^message-id:\s*(.+)$", entete)
    return trouve.group(1).decode(errors="replace").strip() if trouve else ""


def relever_imap(depuis_jours: int | None = None,
                 connus: set[str] | None = None) -> list[bytes]:
    """Récupère les courriels récents. Seule fonction du module qui utilise le réseau.

    Se fait en deux passes : les Message-ID d'abord, puis les corps des seuls
    courriels encore inconnus. Évite de retélécharger toute la boîte toutes les
    deux heures (BIL-1).
    """
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

            numeros = (reponse[0] or b"").split()
            connus = connus or set()

            # Première passe : les en-têtes seuls, pour savoir ce qui est neuf.
            a_lire = []
            for numero in numeros:
                statut, donnees = boite.fetch(
                    numero, "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
                if statut != "OK" or not donnees or not isinstance(donnees[0], tuple):
                    # En-tête illisible : on télécharge quand même le corps,
                    # l'analyse décidera.
                    a_lire.append(numero)
                    continue
                if identifiant_de(donnees[0][1]) not in connus:
                    a_lire.append(numero)

            LOG.info("Relève : %s courriel(s) dans le dossier, %s à lire",
                     len(numeros), len(a_lire))

            # Seconde passe : le corps, uniquement pour les nouveaux.
            messages = []
            for numero in a_lire:
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
