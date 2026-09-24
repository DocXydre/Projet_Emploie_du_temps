"""Ce que le bot affiche : un texte, et des rangées de boutons.

Deux fonctionnalités s'en servent, le sport et les calendriers, et d'autres
suivront. Le type vit donc ici plutôt que chez l'une d'elles : une écran
emprunté à `sport.py` pour parler de calendriers laisserait croire à un lien
entre les deux.
"""

from dataclasses import dataclass, field


@dataclass
class Ecran:
    """Un texte, et des rangées de (libellé, rappel).

    Le rappel est la donnée de callback Telegram, limitée à 64 octets : les
    écrans encodent donc leur état en quelques lettres plutôt qu'en mots.
    """

    texte: str
    boutons: list[list[tuple[str, str]]] = field(default_factory=list)
