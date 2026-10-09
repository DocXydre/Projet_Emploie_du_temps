"""La forme fixe d'une réponse du coach                (COA-17 à COA-20, 9.3)

Un message, et la liste typée de ce que le coach a fait. Cette liste ne vient
jamais du modèle : elle est relue en base, à partir de ce que l'opération a
réellement écrit. Un bouton n'existe que si ce qu'il déclenche existe.

Une action est décrite par son libellé et par la route à appeler : l'application
n'a aucune adresse en dur pour les boutons d'un message.
"""

from api.base import un_seul
from api.coach.clair import clair

# COA-12 : le message fixe, quand le modèle ne répond pas. Il ne donne aucune
# consigne d'urgence : c'est une décision de l'utilisateur (section 11.1).
MESSAGE_INJOIGNABLE = (
    "Le coach est injoignable pour l'instant. Ton message est gardé et sera traité "
    "dès que possible."
)
MESSAGE_SANS_TEXTE = "C'est noté."

TYPES = ("seance_proposee", "seance_retiree", "semaine_a_valider", "ajustement",
         "fenetre_mesure", "avis_objectif", "avis_seance_libre", "plan")


def _action(libelle: str, methode: str, route: str) -> dict:
    return {"libelle": libelle, "methode": methode, "route": route}


def actions(element: dict) -> list[dict]:
    genre = element.get("type")
    if genre == "seance_proposee":
        o = element["id_occurrence"]
        return [_action("Voir", "GET", f"/seances/{o}"),
                _action("Déplacer", "POST", f"/seances/{o}/deplacer"),
                _action("Changer de lieu", "POST", f"/seances/{o}/deplacer"),
                _action("Supprimer", "DELETE", f"/seances/{o}")]
    if genre == "semaine_a_valider":
        return [_action("Valider la semaine", "POST",
                        f"/plan/semaine/valider?lundi={element['lundi']}")]
    if genre == "ajustement":
        a = element["id_ajustement"]
        return [_action("Accepter", "POST", f"/ajustements/{a}/accepter"),
                _action("Refuser", "POST", f"/ajustements/{a}/refuser")]
    if genre == "fenetre_mesure":
        return [_action("Saisir", "POST", "/mesures"),
                _action("Reporter", "POST",
                        f"/mesures/fenetres/{element['id_fenetre']}/reporter")]
    if genre == "avis_objectif":
        return [_action("Modifier l'objectif", "PATCH",
                        f"/objectifs/{element['id_objectif']}")]
    if genre == "plan":
        return [_action("Voir le plan", "GET", "/plan")]
    return []


def elements_de(operation: str) -> list[dict]:
    """COA-18 : ce que l'opération a écrit, avec les actions de chaque élément."""
    ligne = un_seul("SELECT elements_operation(%(o)s) AS elements", {"o": operation})
    elements = clair((ligne or {}).get("elements") or [])
    for element in elements:
        element["actions"] = actions(element)
    return elements


def depuis_echange(echange: dict) -> dict:
    """Un échange enregistré, dans la forme rendue à l'application et au bot."""
    return {"id_echange": echange["id_echange"],
            "moment": echange["moment"],
            "auteur": echange["auteur"],
            "message": echange["contenu"],
            "elements": echange.get("elements") or [],
            "quand": clair(echange.get("quand"))}
