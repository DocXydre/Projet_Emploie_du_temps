"""Ajouter une tâche depuis le bot, question par question                (TAC-20)

Un cycle long (« nettoyer le four, tous les trois mois ») ou une chose à faire
une fois (« rendre le colis avant vendredi »). Cinq questions, des boutons pour
tout sauf le nom : rien à retenir, et rien à taper de travers.

L'état de la saisie est un simple dictionnaire, que le bot garde par personne le
temps de la conversation. Ce module ne sait rien de Telegram : il reçoit l'état
et ce que la personne vient de faire, et rend l'écran suivant.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from html import escape
from zoneinfo import ZoneInfo

from api.base import executer, lister, un_seul
from api.config import configuration
from api.ecran import Ecran
from api.journal import jour_en_clair

RYTHMES = ((7, "Chaque semaine"), (14, "Toutes les 2 semaines"), (30, "Chaque mois"),
           (90, "Tous les 3 mois"), (180, "Tous les 6 mois"))
ECHEANCES = ((0, "Aujourd'hui"), (1, "Demain"), (3, "Dans 3 jours"),
             (7, "Dans une semaine"), (30, "Dans un mois"))
DUREES = ((5, "5 min"), (15, "15 min"), (30, "30 min"), (60, "1 h"))

ANNULER = [("Annuler", "tch:ok:0")]
EXPIREE = "Cette saisie n'est plus en cours. Refais /tache."


def _aujourd_hui() -> date:
    return datetime.now(ZoneInfo(configuration().fuseau)).date()


def _html(texte: str) -> str:
    return escape(texte, quote=False)


def _autres(id_utilisateur: int) -> list[dict]:
    return lister(
        "SELECT id_utilisateur, nom FROM utilisateur "
        " WHERE actif AND id_utilisateur <> %(u)s ORDER BY id_utilisateur",
        {"u": id_utilisateur})


# ---------------------------------------------------------------------------
# Les écrans, dans l'ordre des questions
# ---------------------------------------------------------------------------

def ouvrir(etat: dict, nom: str | None = None) -> Ecran:
    """« /tache », ou « /tache Nettoyer le four » pour sauter la première question."""
    etat.clear()
    if nom and nom.strip():
        return _nommer(etat, nom)
    etat["attend"] = "nom"
    return Ecran("Comment s'appelle la tâche ?\n\n"
                 "Écris son nom, par exemple « Nettoyer le four ».",
                 [[("📋 Celles déjà ajoutées", "tch:liste:0")]])


def _nommer(etat: dict, nom: str) -> Ecran:
    nom = " ".join(nom.split())
    if not 2 <= len(nom) <= 100:
        etat["attend"] = "nom"
        return Ecran("Il me faut un nom de 2 à 100 caractères. Réessaie.")
    etat.update(nom=nom, attend=None)
    return Ecran(f"<b>{_html(nom)}</b>\n\nUne seule fois, ou régulièrement ?",
                 [[("Une seule fois", "tch:g:fois"), ("Régulièrement", "tch:g:reg")],
                  ANNULER])


def _ecran_rythme(etat: dict) -> Ecran:
    boutons = [[(libelle, f"tch:j:{jours}")] for jours, libelle in RYTHMES]
    return Ecran(f"<b>{_html(etat['nom'])}</b>\n\nTous les combien ?",
                 [*boutons, [("Un autre rythme", "tch:j:0")], ANNULER])


def _ecran_echeance(etat: dict) -> Ecran:
    boutons = [[(libelle, f"tch:e:{jours}")] for jours, libelle in ECHEANCES]
    return Ecran(f"<b>{_html(etat['nom'])}</b>\n\nÀ faire avant quand ?",
                 [*boutons, [("Une autre date", "tch:e:x")], ANNULER])


def _ecran_pour(etat: dict, id_utilisateur: int) -> Ecran:
    autres = [(a["nom"], f"tch:p:{a['id_utilisateur']}") for a in _autres(id_utilisateur)]
    return Ecran(f"<b>{_html(etat['nom'])}</b>\n\nC'est pour qui ?",
                 [[("Moi", f"tch:p:{id_utilisateur}"), *autres],
                  [("À tour de rôle", "tch:p:0")], ANNULER])


def _ecran_duree(etat: dict) -> Ecran:
    return Ecran(f"<b>{_html(etat['nom'])}</b>\n\nÇa prend combien de temps ?",
                 [[(libelle, f"tch:d:{minutes}") for minutes, libelle in DUREES], ANNULER])


def _resume(etat: dict, id_utilisateur: int) -> str:
    if etat.get("jours"):
        rythme = next((libelle.lower() for jours, libelle in RYTHMES
                       if jours == etat["jours"]), f"tous les {etat['jours']} jours")
    else:
        echeance = date.fromisoformat(etat["echeance"])
        rythme = f"une fois, avant le {echeance:%d/%m}"

    if not etat.get("pour"):
        qui = "à tour de rôle"
    elif etat["pour"] == id_utilisateur:
        qui = "pour toi"
    else:
        ligne = un_seul("SELECT nom FROM utilisateur WHERE id_utilisateur = %(u)s",
                        {"u": etat["pour"]})
        qui = f"pour {ligne['nom']}" if ligne else "pour quelqu'un"

    duree = next((libelle for minutes, libelle in DUREES if minutes == etat["duree"]),
                 f"{etat['duree']} min")
    return f"{rythme}, {qui}, {duree}"


def _ecran_confirmation(etat: dict, id_utilisateur: int) -> Ecran:
    return Ecran(f"<b>{_html(etat['nom'])}</b>\n{_resume(etat, id_utilisateur)}\n\n"
                 "Je l'ajoute ?",
                 [[("✅ Ajouter", "tch:ok:1"), ("Annuler", "tch:ok:0")]])


# ---------------------------------------------------------------------------
# Ce que la personne écrit
# ---------------------------------------------------------------------------

def _lire_date(texte: str) -> date | None:
    """« 12/10 », « 12/10/2026 », ou « 12 » pour le 12 qui vient."""
    morceaux = texte.replace("-", "/").replace(".", "/").strip().split("/")
    aujourd_hui = _aujourd_hui()
    try:
        jour = int(morceaux[0])
        mois = int(morceaux[1]) if len(morceaux) > 1 else aujourd_hui.month
        annee = int(morceaux[2]) if len(morceaux) > 2 else aujourd_hui.year
        if annee < 100:
            annee += 2000
        lue = date(annee, mois, jour)
    except (ValueError, IndexError):
        return None

    # Sans année, une date passée veut dire l'an prochain. Sans mois, le mois
    # prochain : « avant le 5 », dit le 12, ne parle pas de la semaine dernière.
    if lue < aujourd_hui and len(morceaux) == 2:
        lue = lue.replace(year=annee + 1)
    elif lue < aujourd_hui and len(morceaux) == 1:
        suivant = (aujourd_hui.replace(day=1) + timedelta(days=32)).replace(day=1)
        try:
            lue = suivant.replace(day=jour)
        except ValueError:
            return None
    return lue


def texte(etat: dict, id_utilisateur: int, message: str) -> Ecran | None:
    """Un message libre. Rend None quand aucune question n'attend de réponse."""
    attend = etat.get("attend")
    if attend == "nom":
        return _nommer(etat, message)

    if attend == "jours":
        nombre = message.strip().split()[0] if message.strip() else ""
        if not nombre.isdigit() or not 1 <= int(nombre) <= 730:
            return Ecran("Il me faut un nombre de jours entre 1 et 730. Réessaie.")
        etat.update(jours=int(nombre), echeance=None, attend=None)
        return _ecran_pour(etat, id_utilisateur)

    if attend == "date":
        lue = _lire_date(message)
        if lue is None:
            return Ecran("Je n'ai pas compris cette date. Écris-la comme « 12/10 ».")
        if lue < _aujourd_hui():
            return Ecran("Cette date est déjà passée. Donne-m'en une autre.")
        etat.update(echeance=lue.isoformat(), jours=None, attend=None)
        return _ecran_pour(etat, id_utilisateur)

    return None


# ---------------------------------------------------------------------------
# Ce que la personne touche
# ---------------------------------------------------------------------------

def repondre(etat: dict, id_utilisateur: int, action: str, arguments: str) -> Ecran:
    """Un rappel « tch:<action>:<arguments> » devient un écran."""
    if action == "liste":
        return ecran_liste()
    if action == "stop":
        return arreter(int(arguments))
    if action == "new":
        return ouvrir(etat)

    if action == "ok" and arguments == "0":
        etat.clear()
        return Ecran("Annulé, rien n'a été ajouté.")

    # Tout le reste suppose une saisie en cours. Le bot a pu redémarrer, ou le
    # message être resté dans la conversation depuis la veille.
    if not etat.get("nom"):
        return Ecran(EXPIREE)

    if action == "g":
        if arguments == "reg":
            return _ecran_rythme(etat)
        return _ecran_echeance(etat)

    if action == "j":
        if arguments == "0":
            etat["attend"] = "jours"
            return Ecran("Tous les combien de jours ? Écris un nombre, par exemple « 45 ».")
        etat.update(jours=int(arguments), echeance=None, attend=None)
        return _ecran_pour(etat, id_utilisateur)

    if action == "e":
        if arguments == "x":
            etat["attend"] = "date"
            return Ecran("Avant quelle date ? Écris-la comme « 12/10 ».")
        echeance = _aujourd_hui() + timedelta(days=int(arguments))
        etat.update(echeance=echeance.isoformat(), jours=None, attend=None)
        return _ecran_pour(etat, id_utilisateur)

    if action == "p":
        etat["pour"] = int(arguments) or None
        return _ecran_duree(etat)

    if action == "d":
        etat["duree"] = int(arguments)
        return _ecran_confirmation(etat, id_utilisateur)

    if action == "ok":
        return creer(etat, id_utilisateur)

    raise ValueError(f"Action d'ajout de tâche inconnue : {action}")


def creer(etat: dict, id_utilisateur: int) -> Ecran:
    if not (etat.get("jours") or etat.get("echeance")) or not etat.get("duree"):
        return Ecran(EXPIREE)

    creee = executer(
        "SELECT ajouter_tache(%(nom)s, %(acteur)s, %(jours)s, %(echeance)s, "
        "                     %(pour)s, %(duree)s) AS id_tache",
        {"nom": etat["nom"], "acteur": id_utilisateur, "jours": etat.get("jours"),
         "echeance": etat.get("echeance"), "pour": etat.get("pour"),
         "duree": etat["duree"]})
    assert creee is not None
    resume = _resume(etat, id_utilisateur)
    nom = etat["nom"]
    etat.clear()

    from api.ordonnanceur import placer
    placer()

    premiere = un_seul(
        """
        SELECT lower(o.creneau) AS quand, u.nom
          FROM occurrence o
          LEFT JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
         WHERE o.id_tache = %(t)s AND o.creneau IS NOT NULL
         ORDER BY lower(o.creneau) LIMIT 1
        """, {"t": creee["id_tache"]})
    suite = (f"Première fois : {jour_en_clair(premiere['quand'])}, pour {premiere['nom']}."
             if premiere and premiere["nom"]
             else "Je la placerai dès qu'un jour s'y prête.")
    return Ecran(f"Ajoutée : <b>{_html(nom)}</b>\n{resume}\n\n{suite}",
                 [[("📋 Celles déjà ajoutées", "tch:liste:0")]])


# ---------------------------------------------------------------------------
# Celles qu'on a ajoutées
# ---------------------------------------------------------------------------

def ajoutees() -> list[dict]:
    """Les tâches ajoutées encore vivantes : régulières, ou ponctuelles à faire."""
    return lister(
        """
        SELECT t.id_tache, t.libelle, t.recurrente, t.periodicite_min_jours,
               (SELECT max(upper(o.fenetre)) FROM occurrence o
                 WHERE o.id_tache = t.id_tache
                   AND o.statut IN ('a_placer', 'planifiee', 'notifiee')) AS echeance
          FROM tache t
         WHERE t.ajoutee_par IS NOT NULL
           AND t.active
           AND (t.recurrente
                OR EXISTS (SELECT 1 FROM occurrence o
                            WHERE o.id_tache = t.id_tache
                              AND o.statut IN ('a_placer', 'planifiee', 'notifiee')))
         ORDER BY t.recurrente, t.libelle
        """)


def ecran_liste() -> Ecran:
    taches = ajoutees()
    nouvelle = [("➕ Une nouvelle", "tch:new:0")]
    if not taches:
        return Ecran("Aucune tâche ajoutée pour l'instant.", [nouvelle])

    lignes, boutons = ["<b>Les tâches ajoutées</b>"], []
    for tache in taches:
        if tache["recurrente"]:
            detail = f"tous les {tache['periodicite_min_jours']} jours"
        else:
            detail = f"une fois, avant le {tache['echeance'] - timedelta(hours=1):%d/%m}"
        lignes.append(f"• {_html(tache['libelle'])} : {detail}")
        court = (tache["libelle"] if len(tache["libelle"]) <= 28
                 else tache["libelle"][:27] + "…")
        boutons.append([(f"⏹ Arrêter « {court} »", f"tch:stop:{tache['id_tache']}")])
    return Ecran("\n".join(lignes), [*boutons, nouvelle])


def arreter(id_tache: int) -> Ecran:
    ligne = un_seul("SELECT libelle FROM tache WHERE id_tache = %(t)s", {"t": id_tache})
    arretee = executer("SELECT arreter_tache(%(t)s) AS fait", {"t": id_tache})
    suite = ecran_liste()
    if not ligne or not (arretee or {}).get("fait"):
        return Ecran("Cette tâche n'est plus dans la liste.\n\n" + suite.texte, suite.boutons)
    return Ecran(f"Arrêtée : {_html(ligne['libelle'])}. Ce qui a été fait reste dans "
                 f"l'historique.\n\n{suite.texte}", suite.boutons)
