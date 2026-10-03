"""Le journal des événements, mis en phrases.

La base note ce qui change (voir `sql/048_journal.sql` et `trg_journal`) : pour
chaque objet touché par une action, son état avant et son état après. Ce module
en fait des phrases, et regroupe les lignes par action pour que la cause se lise
à côté de l'effet.

    sam. 3 oct. à 14h02 · Thomas · /absent
    • Absence de Thomas : Lusse, du ven. 9 oct. à 18h00 au dim. 11 oct. à 20h00
    • Aspirateur : passe de Thomas à Lorette, sam. 10 oct. à 10h00

Rien ici n'écrit dans le journal, sauf `noter`, pour les faits qui ne sont pas
une ligne de table : un redémarrage, une relève de la boîte qui n'a rien trouvé.
"""

from __future__ import annotations

import re
import unicodedata
from datetime import datetime, timedelta
from html import escape
from zoneinfo import ZoneInfo

from api.base import executer, lister
from api.config import configuration

JOURS = ("lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim.")
MOIS = ("janv.", "févr.", "mars", "avr.", "mai", "juin",
        "juil.", "août", "sept.", "oct.", "nov.", "déc.")

# Ce qu'une action peut montrer avant de résumer. Un placement touche parfois
# trente occurrences : les lire toutes n'apprend rien de plus que les premières.
MAX_CAUSES = 5
MAX_TACHES = 6
MAX_MESSAGES = 3
# Telegram refuse un message de plus de 4096 caractères.
MAX_TEXTE = 3600

ACTEURS = {
    "ordonnanceur": "automatique",
    "bot": "automatique",
    "api": "automatique",
    "deploiement": "déploiement",
    "direct": "en base, à la main",
}

TYPES_OCCUPATION = {"cours": "Cours", "travail": "Travail", "autre": "Créneau",
                    "sommeil": "Sommeil"}


def noter(objet: str, libelle: str, detail: str | None = None,
          technique: bool = False) -> None:
    """JRN-7 : inscrit un fait qui n'est pas une ligne de table."""
    executer("SELECT noter_evenement(%(o)s, %(l)s, %(d)s, %(t)s)",
             {"o": objet, "l": libelle, "d": detail, "t": technique})


# ---------------------------------------------------------------------------
# Dates
# ---------------------------------------------------------------------------

def _fuseau() -> ZoneInfo:
    return ZoneInfo(configuration().fuseau)


def _instant(texte: str | None) -> datetime | None:
    """Un horodatage tel que PostgreSQL l'écrit en JSON, ou dans un intervalle."""
    if not texte:
        return None
    texte = texte.strip().strip('"').replace(" ", "T")
    # « +00 » : le décalage sans les minutes, que Python ne lit pas partout.
    texte = re.sub(r"([+-]\d{2})$", r"\1:00", texte)
    try:
        return datetime.fromisoformat(texte)
    except ValueError:
        return None


def _bornes(intervalle: str | None) -> tuple[datetime | None, datetime | None]:
    """Les deux bornes d'un tstzrange rendu en texte : ["debut","fin")."""
    if not intervalle or intervalle == "empty":
        return None, None
    debut, _, fin = intervalle.strip("[]()").partition(",")
    return _instant(debut), _instant(fin)


def _jour(instant: datetime) -> str:
    local = instant.astimezone(_fuseau())
    return f"{JOURS[local.weekday()]} {local.day} {MOIS[local.month - 1]}"


def _moment(instant: datetime | None) -> str:
    if instant is None:
        return "sans date"
    local = instant.astimezone(_fuseau())
    return f"{_jour(instant)} à {local:%Hh%M}"


def _creneau(intervalle: str | None) -> str:
    """Quand une tâche est posée. Un rappel de journée n'a pas d'heure utile."""
    debut, fin = _bornes(intervalle)
    if debut is None:
        return "sans créneau"
    local = debut.astimezone(_fuseau())
    journee = fin is not None and fin - debut >= timedelta(hours=20)
    if journee and local.hour == 0 and local.minute == 0:
        return _jour(debut)
    return _moment(debut)


def _periode(intervalle: str | None) -> str:
    debut, fin = _bornes(intervalle)
    if debut is None:
        return "sans date"
    if fin is None or fin.year >= 9999:
        return f"à partir du {_moment(debut)}"
    return f"du {_moment(debut)} au {_moment(fin)}"


# ---------------------------------------------------------------------------
# Phrases
# ---------------------------------------------------------------------------

def _nom(noms: dict[int, str], identifiant) -> str:
    if identifiant is None:
        return "personne"
    return noms.get(int(identifiant), "quelqu'un")


def _occurrence(e: dict, noms: dict[int, str]) -> str:
    avant, apres, tache = e["avant"], e["apres"], e["libelle"] or "Tâche"

    if avant is None:
        qui = _nom(noms, apres.get("id_utilisateur"))
        if apres.get("statut") == "faite":
            return f"{tache} : déclarée faite par {qui}"
        if apres.get("creneau"):
            return f"{tache} : nouvelle, {_creneau(apres['creneau'])} pour {qui}"
        raison = f" ({apres['motif']})" if apres.get("motif") else ""
        return f"{tache} : nouvelle, pas encore placée{raison}"

    if apres is None:
        quand = f", prévue {_creneau(avant['creneau'])}" if avant.get("creneau") else ""
        return f"{tache} : retirée du planning{quand}"

    faits: list[str] = []
    change_de_main = avant.get("id_utilisateur") != apres.get("id_utilisateur")
    statut = apres.get("statut")

    if statut != avant.get("statut"):
        if statut == "faite":
            qui = _nom(noms, apres.get("id_utilisateur"))
            faits.append(f"faite par {qui}, c'était à {_nom(noms, avant.get('id_utilisateur'))}"
                         if change_de_main and avant.get("id_utilisateur") is not None
                         else f"faite par {qui}")
            return f"{tache} : {faits[0]}"
        if statut == "abandonnee":
            # « Couverte par « Litière : vidage complet » » : la raison compte.
            raison = f" ({apres['motif'].lower()})" if apres.get("motif") else ""
            return f"{tache} : abandonnée{raison}"
        if statut == "reportee":
            return f"{tache} : reportée"
        if statut == "notifiee":
            faits.append(f"annoncée à {_nom(noms, apres.get('id_utilisateur'))}")
        elif statut == "a_placer":
            raison = f" ({apres['motif']})" if apres.get("motif") else ""
            return f"{tache} : n'a plus de créneau{raison}"

    qui = _nom(noms, apres.get("id_utilisateur"))
    # « Passe de Thomas à Lorette » n'a de sens que si quelqu'un l'avait.
    if change_de_main and avant.get("id_utilisateur") is not None \
            and apres.get("id_utilisateur") is not None:
        faits.append(f"passe de {_nom(noms, avant.get('id_utilisateur'))} à {qui}")

    if avant.get("creneau") != apres.get("creneau") and apres.get("creneau"):
        if avant.get("creneau"):
            faits.append(f"déplacée de {_creneau(avant['creneau'])} "
                         f"à {_creneau(apres['creneau'])}")
        else:
            faits.append(f"placée {_creneau(apres['creneau'])}"
                         + (f" pour {qui}" if not faits else ""))
    elif change_de_main and apres.get("creneau"):
        faits.append(_creneau(apres["creneau"]) if faits
                     else f"attribuée à {qui}, {_creneau(apres['creneau'])}")

    if avant.get("epinglee") != apres.get("epinglee"):
        faits.append("épinglée" if apres.get("epinglee") else "désépinglée")

    if not faits and avant.get("fenetre") != apres.get("fenetre"):
        _, limite = _bornes(apres.get("fenetre"))
        faits.append(f"à faire avant le {_jour(limite)}" if limite else "échéance changée")

    if not faits and apres.get("motif"):
        faits.append(apres["motif"])

    return f"{tache} : {', '.join(faits) or 'modifiée'}"


def _absence(e: dict, noms: dict[int, str]) -> str:
    avant, apres = e["avant"], e["apres"]
    etat = apres or avant
    qui = _nom(noms, etat.get("id_utilisateur"))
    lieu = etat.get("lieu") or "ailleurs"
    if avant is None:
        billet = ", d'après un billet" if apres.get("origine") == "trajet" else ""
        return f"Absence de {qui} : {lieu}, {_periode(apres['periode'])}{billet}"
    if apres is None:
        return f"Absence de {qui} annulée : {lieu}, {_periode(avant['periode'])}"
    return (f"Absence de {qui} ajustée : {lieu}, {_periode(apres['periode'])} "
            f"(avant : {_periode(avant['periode'])})")


def _proposition(e: dict, noms: dict[int, str]) -> str:
    avant, apres, titre = e["avant"], e["apres"], e["libelle"] or "Week-end"
    etat = apres or avant
    qui = _nom(noms, etat.get("id_utilisateur"))
    if avant is None:
        return f"{titre} repéré pour {qui} : {_periode(apres['periode'])}"
    if apres is None:
        return f"{titre} retiré pour {qui} : {_periode(avant['periode'])}"
    if avant.get("statut") != apres.get("statut"):
        suite = {"ecartee": "écarté", "realisee": "devenu un vrai départ",
                 "perimee": "n'est plus possible",
                 "proposee": "de nouveau proposé"}.get(apres.get("statut"), "modifié")
        return f"{titre} de {qui} : {suite} ({_periode(apres['periode'])})"
    if avant.get("periode") != apres.get("periode"):
        return (f"{titre} de {qui} recalé : {_periode(apres['periode'])} "
                f"(avant : {_periode(avant['periode'])})")
    if apres.get("annoncee_le") and not avant.get("annoncee_le"):
        return f"{titre} annoncé à {qui} : {_periode(apres['periode'])}"
    return f"{titre} de {qui} : modifié"


def _trajet(e: dict, noms: dict[int, str]) -> str:
    avant, apres = e["avant"], e["apres"]
    etat = apres or avant
    qui = _nom(noms, etat.get("id_utilisateur"))
    debut, _ = _bornes(etat.get("periode"))
    detail = f"{etat.get('sens', 'trajet')}, départ {_moment(debut)}"
    if apres is not None and apres.get("statut") == "retenue":
        return f"Train retenu pour {qui} : {e['libelle'] or detail} ({detail})"
    return f"Train abandonné pour {qui} : {e['libelle'] or detail} ({detail})"


def _courriel(e: dict, noms: dict[int, str]) -> str:
    apres, sujet = e["apres"], e["libelle"] or "sans sujet"
    if apres is None:
        return f"Courriel oublié, il sera relu : {sujet}"
    statut = apres.get("statut")
    reference = f" ({apres['reference']})" if apres.get("reference") else ""
    raison = f" : {apres['motif']}" if apres.get("motif") else ""
    if statut == "traite":
        return f"Billet lu pour {_nom(noms, apres.get('id_utilisateur'))}{reference} : {sujet}"
    if statut == "illisible":
        return f"Courriel SNCF illisible{raison} ({sujet})"
    if statut == "refuse":
        return f"Billet refusé{raison} ({sujet})"
    return f"Courriel sans billet{raison} ({sujet})"


def _occupation(e: dict, noms: dict[int, str]) -> str:
    avant, apres = e["avant"], e["apres"]
    etat = apres or avant
    genre = TYPES_OCCUPATION.get(etat.get("type"), "Créneau")
    qui = _nom(noms, etat.get("id_utilisateur"))
    titre = etat.get("libelle") or e["libelle"] or "sans titre"
    if avant is None:
        return f"{genre} ajouté pour {qui} : {titre}, {_periode(apres['periode'])}"
    if apres is None:
        return f"{genre} retiré pour {qui} : {titre}, {_periode(avant['periode'])}"
    if avant.get("periode") != apres.get("periode"):
        return (f"{genre} déplacé pour {qui} : {titre}, {_periode(apres['periode'])} "
                f"(avant : {_periode(avant['periode'])})")
    return f"{genre} modifié pour {qui} : {titre}, {_periode(apres['periode'])}"


def _conflit(e: dict, noms: dict[int, str]) -> str:
    avant, apres, titre = e["avant"], e["apres"], e["libelle"] or "Cours"
    if avant is None:
        return f"Cours en double à départager : {titre}, {_periode(apres['periode'])}"
    if apres is None:
        return f"Question retirée : {titre}"
    if apres.get("statut") == "resolu":
        garde = {"existante": "on garde ce qui était au planning",
                 "nouvelle": "on prend le nouveau"}.get(apres.get("choix"), apres.get("choix"))
        return f"Cours en double tranché : {titre}, {garde}"
    if apres.get("statut") == "caduc":
        return f"Cours en double sans objet : {titre} ({apres.get('motif_caducite')})"
    return f"Cours en double : {titre}, modifié"


def _notification(e: dict, noms: dict[int, str]) -> str:
    avant, apres = e["avant"], e["apres"]
    etat = apres or avant
    qui = _nom(noms, etat.get("id_utilisateur"))
    texte = " ".join((e["libelle"] or "").split())
    extrait = f"« {texte[:90]}{'…' if len(texte) > 90 else ''} »"
    if avant is None:
        return f"Message pour {qui} : {extrait}"
    if apres is None:
        return f"Message pour {qui} annulé avant l'envoi : {extrait}"
    if apres.get("statut") == "echec":
        return f"Envoi raté pour {qui} : {extrait}"
    return f"Message envoyé à {qui} : {extrait}"


CHAMPS_TACHE = {
    "libelle": "nom", "duree_minutes": "durée (min)", "priorite": "priorité",
    "periodicite_min_jours": "tous les (jours, au plus tôt)",
    "periodicite_max_jours": "tous les (jours, au plus tard)",
    "heure_min": "pas avant", "heure_max": "pas après",
    "avant_depart": "à faire avant de partir",
}


def _tache(e: dict, noms: dict[int, str]) -> str:
    avant, apres, titre = e["avant"], e["apres"], e["libelle"] or "Tâche"
    if avant is None:
        return f"Nouvelle tâche : {titre}"
    if apres is None:
        return f"Tâche supprimée : {titre}"
    faits = []
    if avant.get("active") != apres.get("active"):
        faits.append("réactivée" if apres.get("active") else "désactivée")
    if avant.get("id_utilisateur_defaut") != apres.get("id_utilisateur_defaut"):
        faits.append(f"revient à {_nom(noms, apres.get('id_utilisateur_defaut'))}"
                     if apres.get("id_utilisateur_defaut") is not None
                     else "se répartit de nouveau entre vous")
    for champ, nom in CHAMPS_TACHE.items():
        if avant.get(champ) != apres.get(champ):
            faits.append(f"{nom} : {_valeur(avant.get(champ))} → {_valeur(apres.get(champ))}")
    return f"Tâche {titre} : {', '.join(faits) or 'modifiée'}"


def _valeur(valeur) -> str:
    if valeur is None:
        return "rien"
    if isinstance(valeur, bool):
        return "oui" if valeur else "non"
    return str(valeur)


def _utilisateur(e: dict, noms: dict[int, str]) -> str:
    avant, apres = e["avant"] or {}, e["apres"] or {}
    noms_des_champs = {"minimum_sport": "séances de sport par semaine",
                       "actif": "compte actif", "lieu_famille": "lieu de famille",
                       "gare_famille": "gare de famille"}
    faits = [f"{nom} : {_valeur(avant.get(champ))} → {_valeur(apres.get(champ))}"
             for champ, nom in noms_des_champs.items()
             if avant.get(champ) != apres.get(champ)]
    return f"Réglages de {e['libelle']} : {', '.join(faits) or 'modifiés'}"


def _source(e: dict, noms: dict[int, str]) -> str:
    avant, apres, titre = e["avant"], e["apres"], e["libelle"] or "Source"
    if avant is None:
        return f"Source ajoutée : {titre}"
    if apres is None:
        return f"Source supprimée : {titre}"
    if avant.get("etat") != apres.get("etat"):
        return (f"Source en panne : {titre}" if apres.get("etat") == "en_panne"
                else f"Source rétablie : {titre}")
    if avant.get("active") != apres.get("active"):
        return (f"Source suivie de nouveau : {titre}" if apres.get("active")
                else f"Source arrêtée : {titre}")
    return f"Source modifiée : {titre}"


PHRASES = {
    "occurrence": _occurrence, "absence": _absence, "proposition": _proposition,
    "trajet": _trajet, "courriel": _courriel, "occupation": _occupation,
    "conflit": _conflit, "notification": _notification, "tache": _tache,
    "utilisateur": _utilisateur, "source": _source,
}


def phrase(evenement: dict, noms: dict[int, str]) -> str:
    """Un événement, en une ligne lisible."""
    faiseur = PHRASES.get(evenement["objet"])
    if faiseur is None:
        # Un fait noté à la main : son libellé dit déjà tout.
        suite = f" : {evenement['detail']}" if evenement.get("detail") else ""
        return f"{evenement['libelle'] or evenement['objet']}{suite}"
    try:
        return faiseur(evenement, noms)
    except (KeyError, TypeError, ValueError, AttributeError):
        # Une ligne mal formée ne doit pas rendre tout le journal illisible.
        return f"{evenement['libelle'] or evenement['objet']} : modifié"


# ---------------------------------------------------------------------------
# Lecture
# ---------------------------------------------------------------------------

def _sans_accent(texte: str) -> str:
    decompose = unicodedata.normalize("NFD", texte.lower())
    return "".join(c for c in decompose if unicodedata.category(c) != "Mn")


def _comptes() -> tuple[dict[int, str], dict[str, str]]:
    """Les prénoms, par identifiant et par pseudo."""
    lignes = lister("SELECT id_utilisateur, pseudo, nom FROM utilisateur")
    return ({ligne["id_utilisateur"]: ligne["nom"] for ligne in lignes},
            {ligne["pseudo"]: ligne["nom"] for ligne in lignes})


def _routine(evenement: dict) -> bool:
    """Ce qui ne mérite pas une ligne quand on ne l'a pas demandé.

    Un message parti normalement, un courriel sans billet : c'est le cours
    ordinaire des choses. On les compte, on ne les raconte pas.
    """
    avant, apres = evenement["avant"], evenement["apres"]
    if evenement["objet"] == "notification":
        return bool(avant and apres and apres.get("statut") == "envoyee")
    if evenement["objet"] == "courriel":
        return bool(apres and apres.get("statut") == "ignore")
    return False


def _ordre_des_taches(evenement: dict) -> tuple[int, datetime]:
    """Le geste d'abord, ses conséquences ensuite, dans l'ordre du calendrier.

    Cocher une tâche en fait bouger quarante autres par rééquilibrage. Celle
    qu'on a cochée est la raison de tout le reste : elle se lit en premier.
    """
    avant, apres = evenement["avant"] or {}, evenement["apres"] or {}
    geste = (apres.get("statut") in ("faite", "abandonnee", "reportee")
             and apres.get("statut") != avant.get("statut"))
    debut, _ = _bornes((apres or avant).get("creneau") or (apres or avant).get("fenetre"))
    return (0 if geste else 1, debut or datetime.max.replace(tzinfo=ZoneInfo("UTC")))


def lire(mot: str | None = None, admin: bool = False,
         actions: int = 8, jours: int = 90) -> list[dict]:
    """Les dernières actions, de la plus récente à la plus ancienne.

    Chaque action rend ses événements, mis en phrases. Sans mot, on ne lit que
    les actions les plus récentes. Avec un mot, il faut tout parcourir : la
    recherche porte sur les phrases, et ignore les accents.

    JRN-6 : le technique n'est rendu qu'à l'administrateur.
    JRN-9 : avec un mot, seules les actions qui en parlent sont rendues.
    """
    noms, par_pseudo = _comptes()
    evenements = lister(
        """
        WITH recentes AS (
            SELECT operation, max(id_evenement) AS dernier
              FROM evenement
             WHERE quand > now() - make_interval(days => %(jours)s)
               AND (%(admin)s OR NOT technique)
             GROUP BY operation
             ORDER BY dernier DESC
             LIMIT %(limite)s
        )
        SELECT e.id_evenement, e.quand, e.operation, e.acteur, e.origine, e.objet,
               e.id_objet, e.libelle, e.avant, e.apres, e.detail, e.technique
          FROM evenement e
          JOIN recentes r USING (operation)
         WHERE %(admin)s OR NOT e.technique
         ORDER BY e.id_evenement
        """,
        # Trois fois plus d'actions que demandé : certaines ne contiennent que
        # de la routine, et ne donneront aucune ligne.
        {"jours": jours, "admin": admin, "limite": None if mot else actions * 3},
    )

    par_action: dict[str, list[dict]] = {}
    for evenement in evenements:
        evenement["phrase"] = phrase(evenement, noms)
        par_action.setdefault(evenement["operation"], []).append(evenement)

    cherche = _sans_accent(mot) if mot else None
    resultat = []
    for operation, lignes in par_action.items():
        premier = lignes[0]
        qui = ACTEURS.get(premier["acteur"]) or par_pseudo.get(premier["acteur"],
                                                               premier["acteur"])
        if cherche:
            for ligne in lignes:
                ligne["correspond"] = cherche in _sans_accent(
                    f"{ligne['phrase']} {ligne['detail'] or ''}")
            if not any(ligne["correspond"] for ligne in lignes):
                # Le mot peut désigner l'action elle-même : « /pourquoi absent »,
                # « /pourquoi bilan ». Toute l'action répond alors à la question.
                if cherche not in _sans_accent(f"{qui} {premier['origine'] or ''}"):
                    continue
                for ligne in lignes:
                    ligne["correspond"] = True
        resultat.append({
            "operation": operation,
            "quand": max(ligne["quand"] for ligne in lignes),
            "acteur": premier["acteur"],
            "qui": qui,
            "origine": premier["origine"],
            "evenements": lignes,
        })

    resultat.sort(key=lambda action: action["quand"], reverse=True)
    return resultat


def _origine(origine: str | None) -> str:
    if not origine:
        return ""
    for prefixe in ("bot : ", "api : "):
        if origine.startswith(prefixe):
            reste = origine[len(prefixe):]
            return reste if prefixe == "bot : " else f"application ({reste})"
    return origine


def _html(texte: str) -> str:
    """Pour Telegram : seuls les chevrons et l'esperluette sont à protéger."""
    return escape(texte, quote=False)


def lignes_d_action(action: dict, filtre: bool = False) -> list[str]:
    """Les lignes à montrer pour une action, résumées quand il y en a trop."""
    evenements = action["evenements"]
    if filtre:
        retenus = [e for e in evenements if e.get("correspond")]
        # À côté de ce qu'on cherche, ce qui l'a provoqué : une absence, un
        # cours ajouté, un billet lu. C'est la réponse à « pourquoi ».
        causes = [e for e in evenements
                  if not e.get("correspond") and not _routine(e)
                  and e["objet"] not in ("occurrence", "notification")]
    else:
        retenus = [e for e in evenements if not _routine(e)]
        causes = []

    declencheurs = [e for e in retenus if e["objet"] not in ("occurrence", "notification")]
    taches = sorted((e for e in retenus if e["objet"] == "occurrence"), key=_ordre_des_taches)
    messages = [e for e in retenus if e["objet"] == "notification"]

    lignes: list[str] = []
    for groupe, limite, un, plusieurs in (
            (declencheurs, MAX_CAUSES, "autre changement", "autres changements"),
            (taches, MAX_TACHES, "autre tâche modifiée", "autres tâches modifiées"),
            (messages, MAX_MESSAGES, "autre message", "autres messages")):
        lignes += [f"• {_html(e['phrase'])}" for e in groupe[:limite]]
        en_plus = len(groupe) - limite
        if en_plus > 0:
            lignes.append(f"• et {en_plus} {un if en_plus == 1 else plusieurs}")

    if causes:
        lignes.append("<i>Dans la même action :</i>")
        lignes += [f"• {_html(e['phrase'])}" for e in causes[:MAX_CAUSES]]
        if len(causes) > MAX_CAUSES:
            lignes.append(f"• et {len(causes) - MAX_CAUSES} de plus")

    return lignes


def entete(action: dict) -> str:
    """Quand, qui, et par quelle action. En HTML."""
    return " · ".join(morceau for morceau in (
        f"<b>{_moment(action['quand'])}</b>", _html(action["qui"]),
        _html(_origine(action["origine"]))) if morceau)


def raconter(mot: str | None = None, admin: bool = False) -> str:
    """Le texte de /pourquoi, en HTML pour Telegram."""
    combien = 12 if mot else 8

    blocs: list[str] = []
    longueur = 0
    for action in lire(mot, admin=admin, actions=combien):
        lignes = lignes_d_action(action, filtre=bool(mot))
        if not lignes:
            continue
        bloc = "\n".join([entete(action), *lignes])
        if len(blocs) >= combien or longueur + len(bloc) > MAX_TEXTE:
            blocs.append("<i>Le reste est plus ancien. Précise un mot pour le retrouver.</i>")
            break
        blocs.append(bloc)
        longueur += len(bloc) + 2

    if blocs:
        return "\n\n".join(blocs)
    if mot:
        return (f"Rien dans le journal pour « {_html(mot)} » sur les 90 derniers jours. "
                "Essaie un autre mot, ou /pourquoi tout court.")
    return "Le journal est vide pour l'instant. Il se remplit à chaque changement."
