"""Dans quelle action sommes-nous, et qui l'a lancée.

Le journal des événements (JRN) note ce qui change en base. Pour que la cause se
lise à côté de l'effet, chaque changement doit savoir de quelle action il vient :
une commande du bot, un appel de l'API, un passage de l'ordonnanceur. Ce module
tient ce renseignement le temps de l'action, et `api.base` le transmet à
PostgreSQL à chaque transaction.

L'objet est partagé, et c'est voulu. FastAPI exécute la vérification de la clé
et la route elle-même dans deux fils distincts, chacun avec sa copie du
contexte : une variable posée dans le premier ne se verrait pas dans le second.
Les deux copies désignent en revanche le même objet, que la vérification de la
clé peut donc signer.
"""

from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from uuid import uuid4


@dataclass
class Operation:
    origine: str
    acteur: str | None = None
    identifiant: str = field(default_factory=lambda: uuid4().hex[:16])


_courante: ContextVar[Operation | None] = ContextVar("operation", default=None)


def courante() -> Operation | None:
    return _courante.get()


@contextmanager
def ouvrir(origine: str, acteur: str | None = None) -> Iterator[Operation]:
    """Tout ce qui s'écrit en base d'ici la sortie appartient à la même action.

    Une action déjà ouverte est gardée : le placement appelé par une commande
    du bot fait partie de cette commande, pas d'une action à part.
    """
    existante = _courante.get()
    if existante is not None:
        yield existante
        return

    operation = Operation(origine=origine, acteur=acteur)
    jeton = _courante.set(operation)
    try:
        yield operation
    finally:
        _courante.reset(jeton)


def signer(acteur: str) -> None:
    """Qui est derrière l'action en cours, une fois qu'on le sait."""
    operation = _courante.get()
    if operation is not None:
        operation.acteur = acteur


def preciser(origine: str) -> None:
    """Affine l'origine : « bot : bouton » devient « bot : bouton valider »."""
    operation = _courante.get()
    if operation is not None:
        operation.origine = origine
