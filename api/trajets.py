"""Aller à Saint-Dié : trouver quand, trouver comment, geler le ménage.

Trois choses se rencontrent ici, et aucune n'appartient à ce module.

Quand partir est une question d'emploi du temps, et la base y répond seule avec
`fenetres_de_depart` : un creux d'au moins deux jours sans cours ni service.

Comment y aller est une question d'horaires, et la SNCF y répond. On ne garde
ses réponses que le temps qu'un horaire soit choisi.

Ce qu'il advient du ménage est une question d'absence, et la base y répond
encore : retenir un trajet crée l'absence, l'absence libère les jours, et le
placement se refait tout seul.

Ce module ne fait que les mettre en présence.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta

from api.base import executer, lister, un_seul
from api.collecteurs import sncf
from api.collecteurs.sncf import Trajet, TrajetImpossible
from api.config import configuration

LOG = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Fenêtres
# ---------------------------------------------------------------------------

def fenetres(id_utilisateur: int, jours: int | None = None,
             duree_heures: int | None = None) -> list[dict]:
    """Creux assez longs pour valoir un aller-retour."""
    conf = configuration()
    return lister(
        """
        SELECT debut, fin, duree, fin_obligation_avant, debut_obligation_apres,
               depart_au_plus_tot, retour_au_plus_tard
          FROM fenetres_de_depart(%(u)s, now(), now() + make_interval(days => %(j)s),
                                  %(h)s, %(m)s)
        """,
        {
            "u": id_utilisateur,
            "j": jours or conf.horizon_trajets_jours,
            "h": duree_heures or conf.fenetre_absence_heures,
            "m": conf.marge_trajet_minutes,
        },
    )


def rang_contenant(id_utilisateur: int, instant: datetime) -> int | None:
    """Rang de la fenêtre qui contient cet instant, ou None si elle a disparu.

    Sert à faire le lien entre une proposition annoncée il y a quinze jours et
    la fenêtre d'aujourd'hui : entre les deux, un cours a pu tomber au milieu
    et faire disparaître le creux. Mieux vaut le dire que proposer des trains
    pour un week-end qui n'est plus libre.
    """
    for rang, creneau in enumerate(fenetres(id_utilisateur), start=1):
        if creneau["debut"] <= instant < creneau["fin"]:
            return rang
    return None


def fenetre(id_utilisateur: int, rang: int = 1) -> dict | None:
    """La n-ième fenêtre à venir, comptée à partir de 1.

    Le rang plutôt qu'un identifiant : une fenêtre n'est pas une donnée, c'est
    le résultat d'un calcul. Lui donner une clé obligerait à la stocker, donc à
    la tenir à jour à chaque collecte — pour un objet dont la durée de vie utile
    se compte en secondes.
    """
    toutes = fenetres(id_utilisateur)
    if rang < 1 or rang > len(toutes):
        return None
    return toutes[rang - 1]


# ---------------------------------------------------------------------------
# Propositions
# ---------------------------------------------------------------------------

def _enregistrer(id_utilisateur: int, sens: str, trajet: Trajet,
                 origine: str, destination: str,
                 id_trajet_aller: int | None = None) -> dict:
    ligne = executer(
        """
        INSERT INTO trajet (id_utilisateur, sens, periode, origine, destination,
                            correspondances, resume, id_trajet_aller)
        VALUES (%(u)s, %(sens)s, tstzrange(%(depart)s, %(arrivee)s, '[)'),
                %(origine)s, %(destination)s, %(corr)s, %(resume)s, %(aller)s)
        RETURNING id_trajet, lower(periode) AS depart, upper(periode) AS arrivee,
                  correspondances, resume, sens
        """,
        {
            "u": id_utilisateur, "sens": sens,
            "depart": trajet.depart, "arrivee": trajet.arrivee,
            "origine": origine, "destination": destination,
            "corr": trajet.correspondances, "resume": trajet.resume,
            "aller": id_trajet_aller,
        },
    )
    assert ligne is not None
    return ligne


def proposer_aller(id_utilisateur: int, rang: int = 1,
                   charge: dict | None = None) -> dict:
    """Horaires possibles pour partir, sur la fenêtre demandée.

    Le premier train retenu n'est pas le premier du soir mais le premier qu'on
    puisse attraper : la marge après le dernier cours est déjà dans
    `depart_au_plus_tot`.
    """
    creneau = fenetre(id_utilisateur, rang)
    if creneau is None:
        return {"fenetre": None, "trajets": []}

    conf = configuration()
    _, nom_depart = sncf.GARES.get(conf.gare_domicile, ("", conf.gare_domicile))
    _, nom_arrivee = sncf.GARES.get(conf.gare_famille, ("", conf.gare_famille))

    trouves = sncf.chercher(
        conf.gare_domicile, conf.gare_famille,
        pas_avant=creneau["depart_au_plus_tot"],
        # On ne veut pas d'un train qui arrive après la fin de la fenêtre :
        # il ferait rater le retour avant même d'être parti.
        arrive_avant=creneau["fin"],
        charge=charge,
    )

    return {
        "fenetre": creneau,
        "trajets": [_enregistrer(id_utilisateur, "aller", t, nom_depart, nom_arrivee)
                    for t in trouves],
    }


def proposer_retour(id_trajet_aller: int, charge: dict | None = None) -> dict:
    """Horaires pour rentrer, une fois l'aller choisi.

    Deux bornes encadrent la recherche. On ne repart pas avant d'être arrivé —
    et pas non plus dans la foulée : rester deux heures à Saint-Dié n'est pas
    un séjour. Et il faut être rentré avant la première obligation qui suit,
    avec la même marge qu'à l'aller.

    R71 : la recherche part de la seconde borne, pas de la première. Le retour
    qu'on veut est le dernier qui ramène à temps, et les suivants sont proposés
    de plus en plus tôt — chaque heure gagnée est une heure de plus sur place.
    C'est l'inverse de l'aller, où l'on veut partir dès que possible.
    """
    aller = un_seul(
        """
        SELECT t.id_trajet, t.id_utilisateur, lower(t.periode) AS depart,
               upper(t.periode) AS arrivee, t.origine, t.destination
          FROM trajet t
         WHERE t.id_trajet = %(id)s AND t.sens = 'aller'
        """,
        {"id": id_trajet_aller},
    )
    if aller is None:
        raise TrajetImpossible("introuvable", f"Aller {id_trajet_aller} inconnu")

    conf = configuration()

    # La fenêtre qui contient l'aller : c'est elle qui dit jusqu'à quand on
    # peut rester. On la retrouve par sa date plutôt que par un identifiant,
    # puisqu'elle n'en a pas.
    contenante = next(
        (f for f in fenetres(aller["id_utilisateur"], duree_heures=1)
         if f["debut"] <= aller["depart"] < f["fin"]),
        None,
    )
    limite = contenante["retour_au_plus_tard"] if contenante else None

    trouves = sncf.chercher(
        conf.gare_famille, conf.gare_domicile,
        # Un séjour d'une nuit au minimum : sans ce plancher, la SNCF
        # proposerait le train suivant, qui repart avant qu'on soit sorti
        # de la gare.
        pas_avant=aller["arrivee"] + timedelta(hours=12),
        arrive_avant=limite,
        charge=charge,
        # Toujours par la fin. Rentrer le plus tard possible est le
        # comportement voulu, sans exception : avec un cours à 16h30, le train
        # qu'on veut est celui de 14h42, pas celui du matin.
        au_plus_tard=True,
    )

    return {
        "aller": aller,
        "retour_au_plus_tard": limite,
        "trajets": [_enregistrer(aller["id_utilisateur"], "retour", t,
                                 aller["destination"], aller["origine"],
                                 id_trajet_aller=id_trajet_aller)
                    for t in trouves],
    }


# ---------------------------------------------------------------------------
# Décision
# ---------------------------------------------------------------------------

def retenir(id_aller: int, id_retour: int | None = None) -> dict:
    """Transforme des horaires en absence, et refait le planning.

    Le replacement est immédiat et non différé : sans lui, les tâches
    resteraient posées sur des jours où l'on ne sera pas là, et le bot
    enverrait le soir même un rappel pour un appartement vide.
    """
    ligne = un_seul(
        "SELECT retenir_trajet(%(a)s, %(r)s) AS id_absence",
        {"a": id_aller, "r": id_retour},
    )
    assert ligne is not None

    from api.ordonnanceur import placer
    replacees = placer()

    absence = un_seul(
        """
        SELECT id_absence, lower(periode) AS debut, upper(periode) AS fin,
               lieu, commentaire
          FROM absence WHERE id_absence = %(id)s
        """,
        {"id": ligne["id_absence"]},
    )
    return {"absence": absence, "occurrences_replacees": replacees}


def trajets_retenus(id_utilisateur: int) -> list[dict]:
    return lister(
        """
        SELECT id_trajet, sens, depart, arrivee, duree, origine, destination,
               correspondances, resume, id_absence
          FROM v_trajet
         WHERE id_utilisateur = %(u)s AND statut = 'retenue' AND depart > now()
         ORDER BY depart
        """,
        {"u": id_utilisateur},
    )


def oublier(id_absence: int) -> int:
    """Annule une absence issue d'un trajet, et libère ses propositions."""
    executer(
        "UPDATE trajet SET statut = 'ecartee', id_absence = NULL "
        "WHERE id_absence = %(id)s RETURNING id_trajet",
        {"id": id_absence},
    )
    supprimee = executer(
        "DELETE FROM absence WHERE id_absence = %(id)s RETURNING id_absence",
        {"id": id_absence},
    )
    if supprimee is None:
        return 0

    from api.ordonnanceur import placer
    return placer()


# ---------------------------------------------------------------------------
# Mise en forme
# ---------------------------------------------------------------------------

def resumer_fenetre(creneau: dict, fuseau=None) -> str:
    from zoneinfo import ZoneInfo
    fuseau = fuseau or ZoneInfo(configuration().fuseau)

    def _jour(instant: datetime) -> str:
        JOURS = ("lun", "mar", "mer", "jeu", "ven", "sam", "dim")
        local = instant.astimezone(fuseau)
        return f"{JOURS[local.weekday()]} {local.day:02d}/{local.month:02d} " \
               f"{local.hour:02d}h{local.minute:02d}"

    heures = int(creneau["duree"].total_seconds() // 3600)
    texte = f"{_jour(creneau['debut'])} → {_jour(creneau['fin'])} ({heures} h)"

    if creneau["fin_obligation_avant"] is None:
        texte += "\n  rien avant : tu peux partir quand tu veux"
    if creneau["debut_obligation_apres"] is None:
        texte += "\n  rien après dans l'horizon connu"
    return texte
