"""Repère les week-ends libres et les propose sans qu'on les demande.

Repérer et annoncer sont deux gestes distincts (WKD-7). Le creux est repéré
quinze jours avant et s'inscrit au calendrier, en silence : à quinze jours la
question ne se pose pas encore. La notification part une semaine avant, quand
le billet se décide. La relance existe toujours mais est coupée par défaut :
deux week-ends dans la fenêtre faisaient quatre messages pour une question.

Une proposition ne bloque rien dans le planning. Elle s'affiche au calendrier
et cesse de poser la question dès qu'on y répond : refus, billet acheté ou
départ déclaré.
"""

from __future__ import annotations

import logging

from api.base import executer, lister, un_seul
from api.config import configuration

LOG = logging.getLogger(__name__)


def _destinataire(id_utilisateur: int | None) -> int:
    """À qui les propositions s'adressent.

    Les propositions vont à l'administrateur, seul concerné par ces trajets.
    """
    if id_utilisateur is not None:
        return id_utilisateur

    qui = un_seul("SELECT id_utilisateur FROM utilisateur "
                  " WHERE actif AND role = 'admin' ORDER BY id_utilisateur LIMIT 1")
    if qui is None:
        raise ValueError("Aucun administrateur à qui proposer un week-end")
    return qui["id_utilisateur"]


def reperer(id_utilisateur: int | None = None,
            delai_jours: int | None = None) -> list[dict]:
    """Crée une proposition par creux assez long dans le délai voulu.

    TRJ-8 : le lieu est celui de la personne. Proposer Lusse à qui va à
    Saint-Dié n'apprend rien et sonne faux.
    """
    from api.trajets import destination

    conf = configuration()
    qui = _destinataire(id_utilisateur)
    return lister(
        """
        SELECT id_proposition, id_utilisateur,
               lower(periode) AS debut, upper(periode) AS fin, lieu, statut
          FROM proposer_weekends(%(u)s, %(lieu)s, %(delai)s, %(duree)s)
        """,
        {
            "u": qui,
            "lieu": destination(qui)["lieu"],
            "delai": delai_jours or conf.proposition_delai_jours,
            "duree": conf.fenetre_absence_heures,
        },
    )


def a_annoncer(jours: int | None = None) -> list[dict]:
    """Propositions déjà au calendrier dont il est temps de parler.   (WKD-7)"""
    conf = configuration()
    return lister(
        """
        SELECT id_proposition, id_utilisateur,
               lower(periode) AS debut, upper(periode) AS fin, lieu
          FROM propositions_a_annoncer(%(j)s)
        """,
        {"j": jours if jours is not None else conf.proposition_annonce_jours},
    )


def a_relancer(jours: int | None = None) -> list[dict]:
    conf = configuration()
    jours = jours if jours is not None else conf.proposition_relance_jours
    # Zéro jour : la relance est coupée. Mieux vaut un réglage lisible qu'une
    # fonction supprimée qu'il faudrait réécrire pour la remettre.
    if not jours:
        return []
    return lister(
        """
        SELECT id_proposition, id_utilisateur,
               lower(periode) AS debut, upper(periode) AS fin, lieu
          FROM propositions_a_relancer(%(j)s)
        """,
        {"j": jours},
    )


def en_attente(id_utilisateur: int | None = None) -> list[dict]:
    return lister(
        """
        SELECT id_proposition, id_utilisateur,
               lower(periode) AS debut, upper(periode) AS fin, lieu, statut,
               annoncee_le, relancee_le
          FROM proposition
         WHERE statut = 'proposee'
           AND (%(u)s::INT IS NULL OR id_utilisateur = %(u)s)
         ORDER BY lower(periode)
        """,
        {"u": id_utilisateur},
    )


def detail(id_proposition: int) -> dict | None:
    return un_seul(
        """
        SELECT id_proposition, id_utilisateur,
               lower(periode) AS debut, upper(periode) AS fin, lieu, statut
          FROM proposition WHERE id_proposition = %(id)s
        """,
        {"id": id_proposition},
    )


def ecarter(id_proposition: int) -> dict | None:
    """« Non merci. » On ne revient pas à la charge sur un week-end décliné."""
    return executer(
        "UPDATE proposition SET statut = 'ecartee' "
        " WHERE id_proposition = %(id)s AND statut = 'proposee' "
        "RETURNING id_proposition, lower(periode) AS debut, upper(periode) AS fin",
        {"id": id_proposition},
    )


def _annoncer(proposition: dict, texte: str, colonne: str) -> None:
    """Dépose la notification et marque l'étape, dans cet ordre.

    La notification est écrite avant que la proposition ne soit marquée. En
    cas d'échec entre les deux, l'annonce peut partir en double, ce qui se voit
    et se corrige.
    """
    executer(
        "INSERT INTO notification (id_utilisateur, type, contenu, id_proposition) "
        "VALUES (%(u)s, 'alerte', %(texte)s, %(p)s) RETURNING id_notification",
        {"u": proposition["id_utilisateur"], "texte": texte,
         "p": proposition["id_proposition"]},
    )
    executer(
        f"UPDATE proposition SET {colonne} = now() "
        f" WHERE id_proposition = %(id)s RETURNING id_proposition",
        {"id": proposition["id_proposition"]},
    )


def resumer(proposition: dict, relance: bool = False) -> str:
    from api.conversation import _jour

    lieu = f" à {proposition['lieu']}" if proposition.get("lieu") else ""
    entete = ("Ça approche : week-end libre" if relance
              else "Week-end libre repéré")
    return (f"{entete}{lieu}\n"
            f"{_jour(proposition['debut'])} → {_jour(proposition['fin'])}\n\n"
            f"Rien de prévu sur cette période. On regarde les trains ?")


def tour_de_ronde(id_utilisateur: int | None = None) -> dict:
    """Repère, annonce, relance. C'est ce que l'ordonnanceur appelle chaque jour.

    L'entretien passe d'abord : une proposition devenue caduque ne doit pas
    être relancée le matin où l'on vient d'acheter le billet.
    """
    executer("SELECT entretenir_propositions() AS touchees")
    # WKD-9 : la base revérifie avec quarante-huit heures, faute de connaître
    # le réglage. On repasse ici avec la durée configurée, pour qu'un seuil
    # relevé dans le .env s'applique aussi aux propositions déjà faites.
    executer("SELECT reverifier_propositions(%(h)s) AS touchees",
             {"h": configuration().fenetre_absence_heures})

    # WKD-7 : repérer n'est pas annoncer. Celles-ci s'inscrivent au calendrier
    # sans un mot ; elles parleront quand le départ approchera.
    nouvelles = reperer(id_utilisateur)

    annonces = a_annoncer()
    for proposition in annonces:
        _annoncer(proposition, resumer(proposition), "annoncee_le")

    relances = a_relancer()
    for proposition in relances:
        _annoncer(proposition, resumer(proposition, relance=True), "relancee_le")

    if nouvelles or annonces or relances:
        LOG.info("Propositions : %s repérée(s), %s annoncée(s), %s relance(s)",
                 len(nouvelles), len(annonces), len(relances))

    return {"proposees": len(nouvelles), "annoncees": len(annonces),
            "relancees": len(relances)}
