"""Composer ses calendriers depuis le bot                       (NOT-5 à NOT-9).

Un calendrier composé, c'est deux listes : des personnes, et des familles de
contenu. Tout tient donc dans des boutons à cocher, et l'état de la composition
voyage dans la donnée de rappel : « 1-2_cas » se lit « Thomas et Lorette, les
cours, les tâches et le sport ».

Pourquoi l'état dans le rappel plutôt qu'en session : Telegram rejoue les vieux
boutons sans prévenir, et une session côté serveur les ferait répondre à côté,
des heures plus tard, sur une composition dont plus personne ne se souvient.

Chaque bouton porte l'état d'après la coche, et non la coche à appliquer : un
rappel rejoué affiche alors deux fois le même écran, là où une bascule
décocherait ce qu'un premier appui venait de cocher.
"""

from __future__ import annotations

from api import conversation as conv
from api.ecran import Ecran

# Les six familles de NOT-6, dans l'ordre d'affichage, avec la lettre qui les
# désigne dans un rappel : 64 octets ne suffisent pas pour des mots entiers.
CONTENUS: dict[str, tuple[str, str]] = {
    "c": ("cours", "Cours"),
    "t": ("travail", "Travail"),
    "p": ("perso", "Perso"),
    "a": ("taches", "Tâches"),
    "s": ("sport", "Sport"),
    "w": ("weekends", "Week-ends"),
}

LETTRE = {famille: lettre for lettre, (famille, _) in CONTENUS.items()}


# ---------------------------------------------------------------------------
# L'état d'une composition, tel qu'il voyage dans les rappels
# ---------------------------------------------------------------------------

def _lire(etat: str) -> tuple[list[int], list[str]]:
    personnes, _, lettres = etat.partition("_")
    comptes = [int(x) for x in personnes.split("-") if x.isdigit()]
    return comptes, [lettre for lettre in lettres if lettre in CONTENUS]


def _ecrire(personnes: list[int], lettres: list[str]) -> str:
    return "-".join(str(p) for p in sorted(set(personnes))) + "_" + "".join(
        lettre for lettre in CONTENUS if lettre in lettres)


def _basculer(valeurs: list, valeur) -> list:
    """Cocher ce qui ne l'est pas, décocher ce qui l'est."""
    return [v for v in valeurs if v != valeur] if valeur in valeurs else [*valeurs, valeur]


def _nom_propose(personnes: list[int], lettres: list[str]) -> str:
    """« Lorette : cours, sport ». Un nom qu'on reconnaît dans une liste."""
    comptes = {c["id_utilisateur"]: c["nom"] for c in conv.comptes_actifs()}
    qui = " et ".join(comptes.get(p, str(p)) for p in personnes) or "Personne"
    quoi = ", ".join(CONTENUS[lettre][1].lower() for lettre in CONTENUS if lettre in lettres)
    return f"{qui} : {quoi}"[:60]


def _resume(ligne: dict) -> str:
    """« Lorette · cours, sport », dans l'ordre d'affichage des familles."""
    noms = " et ".join(ligne["noms"] or [])
    retenues = set(ligne["contenus"] or [])
    familles = ", ".join(libelle.lower() for famille, libelle in CONTENUS.values()
                         if famille in retenues)
    return f"{noms} · {familles}"


# ---------------------------------------------------------------------------
# Les écrans
# ---------------------------------------------------------------------------

def ecran_liste(id_utilisateur: int) -> Ecran:
    """L'entrée de /calendrier : ce qu'on a déjà, et de quoi en faire un autre."""
    miens = conv.calendriers_de(id_utilisateur)

    lignes = ["<b>Tes calendriers</b>"]
    boutons = []
    for ligne in miens:
        lignes += ["", f"• <b>{ligne['libelle']}</b>", f"  {_resume(ligne)}"]
        boutons.append([(ligne["libelle"][:30], f"cal:v:{ligne['id_calendrier']}")])

    if not miens:
        lignes += ["", "Aucun pour l'instant. Un calendrier composé, c'est une ou "
                       "plusieurs personnes et ce qu'on veut voir d'elles : les cours "
                       "de Lorette, vos tâches à tous les deux, ton sport seul."]

    boutons.append([("➕ Nouveau calendrier", "cal:new:_")])
    boutons.append([("🔑 Mon planning complet", "cal:perso:0")])
    return Ecran("\n".join(lignes), boutons)


def ecran_composition(id_utilisateur: int, etat: str) -> Ecran:
    """Les cases à cocher : qui, puis quoi."""
    personnes, lettres = _lire(etat)
    comptes = conv.comptes_actifs()

    lignes = ["<b>Nouveau calendrier</b>", "",
              "Coche les personnes, puis ce que tu veux voir d'elles."]

    boutons = []
    for compte in comptes:
        coche = "☑" if compte["id_utilisateur"] in personnes else "☐"
        suivant = _ecrire(_basculer(personnes, compte["id_utilisateur"]), lettres)
        boutons.append([(f"{coche} {compte['nom']}", f"cal:new:{suivant}")])

    rangee = []
    for lettre, (_, libelle) in CONTENUS.items():
        coche = "☑" if lettre in lettres else "☐"
        suivant = _ecrire(personnes, _basculer(lettres, lettre))
        rangee.append((f"{coche} {libelle}", f"cal:new:{suivant}"))
        if len(rangee) == 2:
            boutons.append(rangee)
            rangee = []
    if rangee:
        boutons.append(rangee)

    if personnes and lettres:
        lignes += ["", f"Ça donnera : <b>{_nom_propose(personnes, lettres)}</b>"]
        boutons.append([("✅ Créer le lien", f"cal:ok:{etat}")])
    else:
        lignes += ["", "Il faut au moins une personne et un contenu."]

    boutons.append([("↩ Mes calendriers", "cal:menu:0")])
    return Ecran("\n".join(lignes), boutons)


def creer(id_utilisateur: int, etat: str) -> Ecran:
    personnes, lettres = _lire(etat)
    if not personnes or not lettres:
        return ecran_composition(id_utilisateur, etat)

    libelle = _nom_propose(personnes, lettres)
    # Deux calendriers de même composition porteraient le même nom : on numérote
    # plutôt que de refuser, l'un peut servir au téléphone et l'autre au Mac.
    existants = {ligne["libelle"] for ligne in conv.calendriers_de(id_utilisateur)}
    if libelle in existants:
        rang = 2
        while f"{libelle} ({rang})" in existants:
            rang += 1
        libelle = f"{libelle} ({rang})"

    cree = conv.creer_calendrier(id_utilisateur, libelle,
                                 personnes,
                                 [CONTENUS[lettre][0] for lettre in lettres])
    if cree is None:
        return Ecran("Je n'ai pas réussi à créer ce calendrier.",
                     [[("↩ Mes calendriers", "cal:menu:0")]])
    return ecran_lien(id_utilisateur, cree["id_calendrier"])


def ecran_lien(id_utilisateur: int, id_calendrier: int) -> Ecran:
    """L'adresse, et rien d'autre à faire que la coller dans le téléphone."""
    ligne = next((c for c in conv.calendriers_de(id_utilisateur)
                  if c["id_calendrier"] == id_calendrier), None)
    if ligne is None:
        return Ecran("Ce calendrier n'existe plus.", [[("↩ Mes calendriers", "cal:menu:0")]])

    lien = conv.url_abonnement(ligne["jeton"])
    if lien is None:
        return Ecran(
            "Je ne sais pas sous quel nom cette machine est joignable depuis ton "
            "téléphone. Renseigne HOTE_PUBLIC dans le .env, puis relance l'API.",
            [[("↩ Mes calendriers", "cal:menu:0")]])

    texte = (f"<b>{ligne['libelle']}</b>\n{_resume(ligne)}\n\n"
             f"Copie cette adresse :\n\n<code>{lien['url']}</code>\n\n"
             f"puis, sur le téléphone : Réglages → Apps → Calendrier → Comptes → "
             f"Ajouter un compte → Autre → Ajouter un calendrier avec abonnement.")
    if lien["webcal"]:
        texte += f"\n\nSur un ordinateur, ce lien ouvre la boîte d'abonnement :\n{lien['webcal']}"

    return Ecran(texte, [[("🗑 Supprimer", f"cal:d:{id_calendrier}")],
                         [("↩ Mes calendriers", "cal:menu:0")]])


def ecran_suppression(id_utilisateur: int, id_calendrier: int) -> Ecran:
    ligne = next((c for c in conv.calendriers_de(id_utilisateur)
                  if c["id_calendrier"] == id_calendrier), None)
    if ligne is None:
        return ecran_liste(id_utilisateur)
    return Ecran(
        f"Supprimer <b>{ligne['libelle']}</b> ? Son adresse cessera de répondre, "
        f"et le calendrier disparaîtra des téléphones abonnés.",
        [[("🗑 Supprimer", f"cal:sup:{id_calendrier}"),
          ("↩ Annuler", f"cal:v:{id_calendrier}")]])


def supprimer(id_utilisateur: int, id_calendrier: int) -> Ecran:
    conv.supprimer_calendrier(id_utilisateur, id_calendrier)
    ecran = ecran_liste(id_utilisateur)
    return Ecran("Calendrier supprimé.\n\n" + ecran.texte, ecran.boutons)


def ecran_personnel(id_utilisateur: int) -> Ecran:
    """Le lien historique : tout son planning, à soi seul."""
    lien = conv.url_calendrier(id_utilisateur)
    if lien is None:
        return Ecran(
            "Je ne sais pas sous quel nom cette machine est joignable depuis ton "
            "téléphone. Renseigne HOTE_PUBLIC dans le .env, puis relance l'API.",
            [[("↩ Mes calendriers", "cal:menu:0")]])

    texte = ("<b>Ton planning complet</b>\nTout ce qui te concerne : cours, travail, "
             "perso, tâches, sport et week-ends.\n\n"
             f"Copie cette adresse :\n\n<code>{lien['url']}</code>\n\n"
             "puis, sur le téléphone : Réglages → Apps → Calendrier → Comptes → "
             "Ajouter un compte → Autre → Ajouter un calendrier avec abonnement.")
    if lien["webcal"]:
        texte += f"\n\nSur un ordinateur : {lien['webcal']}"

    return Ecran(texte, [[("↩ Mes calendriers", "cal:menu:0")]])


def repondre(id_utilisateur: int, action: str, arguments: str) -> Ecran:
    """Un rappel « cal:<action>:<arguments> » devient un écran."""
    if action == "menu":
        return ecran_liste(id_utilisateur)
    if action == "new":
        return ecran_composition(id_utilisateur, arguments)
    if action == "ok":
        return creer(id_utilisateur, arguments)
    if action == "v":
        return ecran_lien(id_utilisateur, int(arguments))
    if action == "d":
        return ecran_suppression(id_utilisateur, int(arguments))
    if action == "sup":
        return supprimer(id_utilisateur, int(arguments))
    if action == "perso":
        return ecran_personnel(id_utilisateur)

    raise ValueError(f"Action de calendrier inconnue : {action}")
