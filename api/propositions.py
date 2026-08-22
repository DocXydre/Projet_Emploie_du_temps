"""Proposer un week-end plutôt que d'attendre qu'on le demande.

Le système savait déjà repérer un creux de deux jours. Il ne le disait que si
on le lui demandait, ce qui suppose d'y penser — et si l'on y pensait, on
n'aurait pas besoin du système.

Deux échéances, et deux seulement. Quinze jours avant, quand un billet coûte
encore peu et qu'on peut s'organiser. Trois jours avant, parce qu'entre les
deux on a oublié. Une troisième relance ne servirait qu'à faire couper les
notifications.

Une proposition ne gèle rien. Elle s'affiche au calendrier, attend une réponse,
et disparaît dès qu'on en a une — un « non merci », un billet acheté, ou un
départ déclaré à la main.
"""

from __future__ import annotations

import logging

from api.base import executer, lister, un_seul
from api.config import configuration

LOG = logging.getLogger(__name__)


def _destinataire(id_utilisateur: int | None) -> int:
    """À qui les propositions s'adressent.

    Le voyage est, dans ce modèle, l'affaire de l'administrateur : c'est lui
    qui a une famille à l'autre bout de la ligne. Un drapeau par utilisateur
    serait plus juste et n'a personne à servir aujourd'hui.
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
    """Crée une proposition par creux assez long dans le délai voulu."""
    conf = configuration()
    return lister(
        """
        SELECT id_proposition, id_utilisateur,
               lower(periode) AS debut, upper(periode) AS fin, lieu, statut
          FROM proposer_weekends(%(u)s, %(lieu)s, %(delai)s, %(duree)s)
        """,
        {
            "u": _destinataire(id_utilisateur),
            "lieu": conf.lieu_famille,
            "delai": delai_jours or conf.proposition_delai_jours,
            "duree": conf.fenetre_absence_heures,
        },
    )


def a_relancer(jours: int | None = None) -> list[dict]:
    conf = configuration()
    return lister(
        """
        SELECT id_proposition, id_utilisateur,
               lower(periode) AS debut, upper(periode) AS fin, lieu
          FROM propositions_a_relancer(%(j)s)
        """,
        {"j": jours or conf.proposition_relance_jours},
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

    Marquer avant d'écrire perdrait l'annonce en cas d'échec ; écrire sans
    marquer la répéterait à chaque passage. L'ordre choisi risque au pire une
    annonce en double, ce qui se voit et se corrige, plutôt qu'un silence.
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

    nouvelles = reperer(id_utilisateur)
    for proposition in nouvelles:
        _annoncer(proposition, resumer(proposition), "annoncee_le")

    relances = a_relancer()
    for proposition in relances:
        _annoncer(proposition, resumer(proposition, relance=True), "relancee_le")

    if nouvelles or relances:
        LOG.info("Propositions : %s nouvelle(s), %s relance(s)",
                 len(nouvelles), len(relances))

    return {"proposees": len(nouvelles), "relancees": len(relances)}
