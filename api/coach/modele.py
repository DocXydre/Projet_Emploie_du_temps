"""L'appel au fournisseur du modèle.

Un seul fournisseur, des outils déclarés en JSON, un cache pour la partie fixe
de la consigne. Ce fichier est le seul à connaître le SDK : la boucle reçoit un
tour, c'est-à-dire du texte, des demandes d'outils et ce que le tour a consommé.

Les tests remplacent `appeler` par un faux modèle : aucun appel payant n'est
fait pendant la suite.
"""

from dataclasses import dataclass, field

from api.config import configuration


class ModeleInjoignable(Exception):
    """Le modèle n'a pas répondu : pas de clé, délai dépassé, erreur du fournisseur."""


@dataclass
class DemandeOutil:
    identifiant: str
    nom: str
    arguments: dict


@dataclass
class Tour:
    texte: str = ""
    outils: list[DemandeOutil] = field(default_factory=list)
    # Le contenu tel que le fournisseur l'a rendu, à lui renvoyer au tour suivant.
    brut: list = field(default_factory=list)
    arret: str = ""
    tokens_entree: int = 0
    tokens_cache: int = 0
    tokens_sortie: int = 0


_client = None


def _le_client():
    global _client
    conf = configuration()
    if not conf.anthropic_api_key:
        raise ModeleInjoignable("Aucune clé d'API n'est configurée (ANTHROPIC_API_KEY)")
    if _client is None:
        import anthropic
        # Les nouveaux essais sont ceux du coach (COA-11), pas ceux du SDK : un
        # appel à la demande n'a que 90 secondes devant lui.
        _client = anthropic.Anthropic(api_key=conf.anthropic_api_key, max_retries=1)
    return _client


def appeler(systeme: list[dict], messages: list[dict], outils: list[dict],
            delai: float) -> Tour:
    """Un tour : la consigne, la conversation, les outils permis, et la réponse."""
    import anthropic

    conf = configuration()
    try:
        reponse = _le_client().messages.create(
            model=conf.coach_modele,
            max_tokens=conf.coach_max_tokens,
            system=systeme,
            messages=messages,
            tools=outils,
            timeout=max(delai, 5.0),
        )
    except anthropic.APIError as erreur:
        raise ModeleInjoignable(f"{type(erreur).__name__} : {erreur}") from erreur

    tour = Tour(arret=reponse.stop_reason or "")
    for bloc in reponse.content:
        if bloc.type == "text":
            tour.texte += bloc.text
            tour.brut.append({"type": "text", "text": bloc.text})
        elif bloc.type == "tool_use":
            tour.outils.append(DemandeOutil(bloc.id, bloc.name, dict(bloc.input or {})))
            tour.brut.append({"type": "tool_use", "id": bloc.id, "name": bloc.name,
                              "input": bloc.input})

    usage = reponse.usage
    lus = getattr(usage, "cache_read_input_tokens", 0) or 0
    ecrits = getattr(usage, "cache_creation_input_tokens", 0) or 0
    # COA-21 : l'entrée compte tout ce que le modèle a lu, cache compris. La
    # part relue depuis le cache, facturée moins cher, est comptée à part.
    tour.tokens_entree = (usage.input_tokens or 0) + lus + ecrits
    tour.tokens_cache = lus
    tour.tokens_sortie = usage.output_tokens or 0
    return tour
