"""Export iCalendar.

Le format prévoit un composant VTODO pour les tâches à cocher, inutilisable
ici : un calendrier abonné qui n'en contient que s'affiche vide sur iOS, et un
abonnement est de toute façon en lecture seule.

On produit donc uniquement des VEVENT — horaires pour les occupations et les
tâches à heure imposée, journée entière pour les rappels.

La validation passe par Telegram ou par l'API : le calendrier sert à voir.
"""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from icalendar import Calendar, Event

from api.base import lister
from api.config import configuration

# Préfixes qui rendent le planning lisible d'un coup d'œil sur téléphone.
PREFIXES = {
    "cours": "Cours",
    "travail": "Travail",
    "sommeil": "Sommeil",
    "menage": "Ménage",
    "linge": "Linge",
    "vaisselle": "Vaisselle",
    "animal": "Chat",
    "admin": "Admin",
    "sport": "Sport",
    "trajet": "Proposition",
}


def _identifiant(ligne: dict) -> str:
    return f"{ligne['nature']}-{ligne['id']}@planif.local"


def _titre(ligne: dict) -> str:
    prefixe = PREFIXES.get(ligne["categorie"], ligne["categorie"])
    libelle = ligne["libelle"]

    # Pour le sport, le lieu remplace le libellé : « Sport : Piscine du
    # SUAPS » est plus utile que « Sport : Séance de sport ».
    if ligne["categorie"] == "sport" and ligne.get("lieu"):
        libelle = ligne["lieu"]

    titre = f"{prefixe} : {libelle}"

    # Le retard se voit dans le titre : c'est la seule information que le
    # calendrier ne peut pas afficher autrement.
    if ligne["nature"] == "tache" and (ligne.get("nb_relances") or 0) > 0:
        titre = f"⚠ {titre} (en retard de {ligne['nb_relances']} j)"
    return titre


def flux_ics(id_utilisateur: int, jours: int | None = None) -> bytes:
    conf = configuration()
    fuseau = ZoneInfo(conf.fuseau)
    debut = datetime.now(fuseau) - timedelta(days=1)

    # L'horizon d'affichage n'est pas celui de la planification : on veut voir
    # ses cours de novembre, même si aucune tâche ménagère n'y sera placée.
    fin = debut + timedelta(days=(jours or conf.horizon_calendrier_jours) + 1)

    lignes = lister(
        """
        SELECT nature, id, categorie, libelle, debut, fin,
               journee_entiere, statut, lieu, motif, nb_relances
          FROM v_planning
         WHERE id_utilisateur = %(u)s
           AND debut < %(fin)s AND fin > %(debut)s
         ORDER BY debut
        """,
        {"u": id_utilisateur, "debut": debut, "fin": fin},
    )

    calendrier = Calendar()
    calendrier.add("prodid", "-//Planification personnelle//FR")
    calendrier.add("version", "2.0")
    calendrier.add("calscale", "GREGORIAN")
    calendrier.add("method", "PUBLISH")
    calendrier.add("x-wr-calname", "Planning")
    calendrier.add("x-wr-timezone", conf.fuseau)

    for ligne in lignes:
        evenement = Event()
        evenement.add("uid", _identifiant(ligne))
        evenement.add("summary", _titre(ligne))
        evenement.add("dtstamp", datetime.now(fuseau))

        if ligne["journee_entiere"]:
            # DTSTART;VALUE=DATE : la bibliothèque le produit dès qu'on lui
            # passe un objet date et non un datetime.
            jour = ligne["debut"].astimezone(fuseau).date()
            # La fin réelle, et non systématiquement le lendemain : un rappel
            # tient sur une journée, une proposition de week-end sur trois. La
            # borne de fin d'un événement journée entière est exclusive, donc
            # la date de fin convient telle quelle.
            fin = max(ligne["fin"].astimezone(fuseau).date(), jour + timedelta(days=1))
            evenement.add("dtstart", jour)
            evenement.add("dtend", fin)
            evenement.add("transp", "TRANSPARENT")  # ne bloque pas la journée
        else:
            evenement.add("dtstart", ligne["debut"].astimezone(fuseau))
            evenement.add("dtend", ligne["fin"].astimezone(fuseau))

        if ligne["lieu"]:
            evenement.add("location", ligne["lieu"])
        if ligne["motif"]:
            evenement.add("description", ligne["motif"])

        calendrier.add_component(evenement)

    return calendrier.to_ical()
