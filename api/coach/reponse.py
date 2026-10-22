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
         "fenetre_mesure", "avis_objectif", "avis_seance_libre", "plan", "demande")


def _action(libelle: str, methode: str, route: str) -> dict:
    return {"libelle": libelle, "methode": methode, "route": route}


def actions(element: dict) -> list[dict]:
    genre = element.get("type")
    if genre == "seance_proposee":
        o = element["id_occurrence"]
        return [_action("Valider", "POST", f"/seances/{o}/valider"),
                _action("Voir", "GET", f"/seances/{o}"),
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
    if genre == "demande":
        # ACC-5, ACC-12 : l'accord se donne d'un bouton, jamais par un outil.
        d = element["id_demande"]
        return [_action("Accepter", "POST", f"/demandes/{d}/accepter"),
                _action("Refuser", "POST", f"/demandes/{d}/refuser")]
    return []


def elements_de(operation: str) -> list[dict]:
    """COA-18 : ce que l'opération a écrit, avec les actions de chaque élément."""
    ligne = un_seul("SELECT elements_operation(%(o)s) AS elements", {"o": operation})
    elements = clair((ligne or {}).get("elements") or [])
    for element in elements:
        element["actions"] = actions(element)
    return elements


def etat_des_elements(id_utilisateur: int, elements: list[dict]) -> list[dict]:
    """Un échange relu garde ses éléments tels qu'ils étaient. Chacun reçoit son
    état d'aujourd'hui : un ajustement déjà accepté n'offre plus ses boutons.

    « en_attente » : les boutons servent encore. Sinon, ce qui s'est passé."""
    for element in elements:
        genre = element.get("type")
        etat = "en_attente"
        if genre == "ajustement" and element.get("id_ajustement"):
            ligne = un_seul("""SELECT a.statut FROM ajustement a
                                 JOIN occurrence o ON o.id_occurrence = a.id_occurrence
                                WHERE a.id_ajustement = %(a)s AND o.id_utilisateur = %(u)s""",
                            {"a": element["id_ajustement"], "u": id_utilisateur})
            statut = (ligne or {}).get("statut") or "disparu"
            etat = "en_attente" if statut == "propose" else statut
        elif genre == "seance_proposee" and element.get("id_occurrence"):
            ligne = un_seul("""SELECT situation FROM v_seance_coach
                                WHERE id_occurrence = %(o)s AND id_utilisateur = %(u)s""",
                            {"o": element["id_occurrence"], "u": id_utilisateur})
            situation = (ligne or {}).get("situation") or "supprimee"
            etat = "en_attente" if situation in ("proposee", "esquisse") else situation
        elif genre == "semaine_a_valider" and element.get("lundi"):
            ligne = un_seul("""SELECT count(*) FILTER (WHERE situation = 'proposee') AS n
                                 FROM v_seance_coach
                                WHERE id_utilisateur = %(u)s AND lundi = %(l)s::DATE""",
                            {"u": id_utilisateur, "l": element["lundi"]})
            etat = "en_attente" if (ligne or {}).get("n") else "validee"
        elif genre == "demande" and element.get("id_demande"):
            ligne = un_seul("""SELECT etat FROM demande
                                WHERE id_demande = %(d)s AND id_utilisateur = %(u)s""",
                            {"d": element["id_demande"], "u": id_utilisateur})
            statut = (ligne or {}).get("etat") or "disparu"
            etat = {"acceptee": "accepte", "refusee": "refuse"}.get(statut, statut)
        elif genre == "fenetre_mesure" and element.get("id_fenetre"):
            ligne = un_seul("""SELECT statut FROM fenetre_mesure
                                WHERE id_fenetre = %(f)s AND id_utilisateur = %(u)s""",
                            {"f": element["id_fenetre"], "u": id_utilisateur})
            statut = (ligne or {}).get("statut") or "disparu"
            etat = "en_attente" if statut == "ouverte" else statut
        element["etat"] = etat
    return elements


def depuis_echange(echange: dict) -> dict:
    """Un échange enregistré, dans la forme rendue à l'application et au bot."""
    message = echange["contenu"]
    if echange["auteur"] == "client":
        # MCP-12 : le résumé d'une conversation tenue ailleurs dit où.
        message = f"Conversation dans {echange.get('client')} : {message}"
    return {"id_echange": echange["id_echange"],
            "moment": echange["moment"],
            "auteur": echange["auteur"],
            "message": message,
            "elements": echange.get("elements") or [],
            "quand": clair(echange.get("quand")),
            # HDF : de quel HAL vient le message, pour l'appli qui en montre deux.
            "hal": echange.get("hal") or "sport"}
