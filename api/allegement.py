"""Le mode allégé                                                        (PLA-16)

Une semaine d'examens, un coup de fatigue : celui qui l'active fait un quart des
tâches partagées pendant la durée qu'il donne, et l'autre en prend trois quarts.
Activé par les deux en même temps, il s'annule.

La règle elle-même vit en base (`choisir_assigne`, `est_allege`). Ce module ne
fait que l'allumer, l'éteindre, prévenir l'autre et dire où on en est.
"""

from __future__ import annotations

from datetime import timedelta

from api.base import executer, lister, un_seul
from api.ecran import Ecran
from api.journal import jour_en_clair

DUREES = ((1, "Aujourd'hui"), (3, "3 jours"), (7, "1 semaine"))


def _autres(id_utilisateur: int) -> list[dict]:
    return lister(
        "SELECT id_utilisateur, nom FROM utilisateur "
        " WHERE actif AND id_utilisateur <> %(u)s ORDER BY id_utilisateur",
        {"u": id_utilisateur})


def _nom(id_utilisateur: int) -> str:
    ligne = un_seul("SELECT nom FROM utilisateur WHERE id_utilisateur = %(u)s",
                    {"u": id_utilisateur})
    return ligne["nom"] if ligne else "Quelqu'un"


def en_cours(id_utilisateur: int) -> dict | None:
    """Le mode allégé de quelqu'un, s'il tourne en ce moment."""
    return un_seul(
        "SELECT id_allegement, lower(periode) AS debut, upper(periode) AS fin "
        "  FROM allegement WHERE id_utilisateur = %(u)s AND periode @> now()",
        {"u": id_utilisateur})


def _dernier_soir(fin) -> str:
    """La période finit à minuit : le dernier jour allégé est la veille."""
    return f"{jour_en_clair(fin - timedelta(hours=1))} au soir"


def _prevenir(id_utilisateur: int, texte: str) -> None:
    executer("INSERT INTO notification (id_utilisateur, type, contenu) "
             "VALUES (%(u)s, 'alerte', %(t)s)", {"u": id_utilisateur, "t": texte})


def _replacer() -> None:
    from api.ordonnanceur import placer
    placer()


def activer(id_utilisateur: int, jours: int) -> Ecran:
    executer("SELECT activer_allegement(%(u)s, %(j)s)", {"u": id_utilisateur, "j": jours})
    _replacer()

    mien = en_cours(id_utilisateur)
    assert mien is not None
    jusqu_a = _dernier_soir(mien["fin"])
    moi = _nom(id_utilisateur)
    lignes = [f"C'est noté : mode allégé jusqu'à {jusqu_a}."]

    for autre in _autres(id_utilisateur):
        sien = en_cours(autre["id_utilisateur"])
        if sien is None:
            lignes.append(f"Tu fais un quart des tâches partagées, {autre['nom']} le reste. "
                          "Ce qui t'est réservé reste à toi.")
            _prevenir(autre["id_utilisateur"],
                      f"{moi} passe en mode allégé jusqu'à {jusqu_a} : tu récupères "
                      "une partie de ses tâches d'ici là.")
        else:
            commun = _dernier_soir(min(mien["fin"], sien["fin"]))
            lignes.append(f"{autre['nom']} l'est aussi. Jusqu'à {commun}, les deux "
                          "s'annulent : la répartition reste moitié-moitié.")
            _prevenir(autre["id_utilisateur"],
                      f"{moi} passe aussi en mode allégé. Jusqu'à {commun}, les deux "
                      "s'annulent : la répartition reste moitié-moitié.")

    return Ecran("\n".join(lignes), [[("Arrêter", "alg:stop:0")]])


def arreter(id_utilisateur: int) -> Ecran:
    arrete = executer("SELECT arreter_allegement(%(u)s) AS fait", {"u": id_utilisateur})
    if not (arrete or {}).get("fait"):
        return Ecran("Tu n'es pas en mode allégé.")

    _replacer()
    moi = _nom(id_utilisateur)
    for autre in _autres(id_utilisateur):
        _prevenir(autre["id_utilisateur"],
                  f"{moi} a arrêté son mode allégé : la répartition redevient "
                  "moitié-moitié.")
    return Ecran("Mode allégé arrêté. La répartition redevient moitié-moitié.")


def ecran(id_utilisateur: int) -> Ecran:
    """Où on en est, et les durées possibles."""
    durees = [[(libelle, f"alg:j:{jours}") for jours, libelle in DUREES]]
    mien = en_cours(id_utilisateur)

    if mien is None:
        autres = " et ".join(a["nom"] for a in _autres(id_utilisateur)) or "l'autre"
        return Ecran(
            "Le mode allégé, c'est pour les jours où tu veux en faire moins : tu "
            f"fais un quart des tâches partagées, {autres} en prend trois quarts. "
            "Ce qui t'est réservé reste à toi.\n\nPour combien de temps ?",
            durees)

    lignes = [f"Tu es en mode allégé jusqu'à {_dernier_soir(mien['fin'])}."]
    for autre in _autres(id_utilisateur):
        sien = en_cours(autre["id_utilisateur"])
        if sien is not None:
            commun = _dernier_soir(min(mien["fin"], sien["fin"]))
            lignes.append(f"{autre['nom']} l'est aussi : jusqu'à {commun}, les deux "
                          "s'annulent.")
    lignes.append("\nChanger la durée, à partir d'aujourd'hui :")
    return Ecran("\n".join(lignes), [*durees, [("Arrêter", "alg:stop:0")]])


def repondre(id_utilisateur: int, action: str, arguments: str) -> Ecran:
    """Un rappel « alg:<action>:<arguments> » devient un écran."""
    if action == "j":
        return activer(id_utilisateur, int(arguments))
    if action == "stop":
        return arreter(id_utilisateur)
    if action == "menu":
        return ecran(id_utilisateur)
    raise ValueError(f"Action de mode allégé inconnue : {action}")


def commande(id_utilisateur: int, arguments: list[str]) -> Ecran:
    """« /allege », « /allege 3 », « /allege stop »."""
    if not arguments:
        return ecran(id_utilisateur)
    mot = arguments[0].lower()
    if mot in ("stop", "fin", "arret", "arrêt", "non"):
        return arreter(id_utilisateur)
    if mot.isdigit() and 1 <= int(mot) <= 14:
        return activer(id_utilisateur, int(mot))
    return Ecran("Donne un nombre de jours entre 1 et 14, par exemple « /allege 3 », "
                 "ou « /allege stop » pour arrêter.")
