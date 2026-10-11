"""Le texte exact envoyé au modèle, appel par appel, dans un fichier.

Pour régler la consigne, il faut voir ce que le modèle a réellement lu : les
trois blocs de consigne, la conversation, chaque outil demandé avec son
résultat entier, et sa réponse. Un fichier Markdown par appel, dans le dossier
réglé par COACH_TRACE_DOSSIER. Vide, rien n'est écrit : c'est le cas sur le
serveur, où ces fichiers contiendraient des données de santé en clair.
"""

import json
import logging
from pathlib import Path

from api.coach.clair import maintenant
from api.config import configuration

LOG = logging.getLogger(__name__)

TITRES_DES_BLOCS = ("Consigne, sommaire et socle du dossier",
                    "Paquets du dossier joints à cet appel",
                    "Contexte de l'utilisateur et mémoire")


def _taille(texte: str) -> str:
    # Environ 2,2 caractères par token : mesuré sur les appels du 11/10 (texte
    # français, tableaux et JSON mêlés). Un ordre de grandeur.
    return f"{len(texte)} caractères, environ {round(len(texte) / 2.2):,} tokens".replace(
        ",", " ")


def _bloc_de_code(texte: str) -> str:
    return "````text\n" + texte.rstrip() + "\n````"


def _contenu(bloc: dict) -> list[str]:
    genre = bloc.get("type")
    if genre == "text":
        return [_bloc_de_code(bloc["text"])]
    if genre == "tool_use":
        return [f"**Outil demandé : `{bloc['name']}`**",
                "```json\n" + json.dumps(bloc.get("input") or {}, ensure_ascii=False,
                                          indent=2) + "\n```"]
    if genre == "tool_result":
        contenu = bloc.get("content")
        if not isinstance(contenu, str):
            contenu = json.dumps(contenu, ensure_ascii=False)
        try:
            contenu = json.dumps(json.loads(contenu), ensure_ascii=False, indent=2)
            langue = "json"
        except (TypeError, ValueError):
            langue = "text"
        refus = " (REFUS)" if bloc.get("is_error") else ""
        return [f"**Résultat{refus}** ({_taille(contenu)})",
                f"```{langue}\n{contenu}\n```"]
    return [_bloc_de_code(json.dumps(bloc, ensure_ascii=False))]


def ecrire(id_appel: int, moment: str, suivi: dict, texte_final: str | None,
           motif_echec: str | None = None) -> Path | None:
    dossier = configuration().coach_trace_dossier
    if not dossier or "systeme" not in suivi:
        return None
    try:
        chemin = Path(dossier)
        chemin.mkdir(parents=True, exist_ok=True)
        fichier = chemin / f"appel_{id_appel:05d}.md"
        lignes = [
            f"# Appel {id_appel} : {moment}, {maintenant():%d/%m/%Y %H:%M}",
            "",
            f"- Modèle : {configuration().coach_modele}",
            "- Paquets du dossier : " + (", ".join(
                f"{code} ({detail})" for code, detail in (suivi.get("choix") or {}).items())
                or "socle seul"),
            f"- Tours d'outils : {suivi.get('tours', 0)}",
            f"- Tokens : {suivi.get('entree', 0)} lus en tout, dont {suivi.get('cache', 0)} "
            f"relus du cache et {suivi.get('cache_ecrit', 0)} écrits en cache ; "
            f"{suivi.get('sortie', 0)} écrits par le modèle",
        ]
        if motif_echec:
            lignes.append(f"- ÉCHEC : {motif_echec}")
        lignes += ["", "Le modèle reçoit à chaque passage les trois blocs de consigne, puis "
                   "toute la conversation ci-dessous. Les outils qu'il peut appeler (leur "
                   "description) sont envoyés aussi, mais ne sont pas recopiés ici.", ""]

        for rang, bloc in enumerate(suivi["systeme"]):
            titre = TITRES_DES_BLOCS[rang] if rang < len(TITRES_DES_BLOCS) else f"Bloc {rang}"
            lignes += [f"## Consigne {rang + 1} : {titre} ({_taille(bloc['text'])})", "",
                       _bloc_de_code(bloc["text"]), ""]

        passage = 0
        for message in suivi.get("messages", []):
            contenus = message["content"]
            if isinstance(contenus, str):
                contenus = [{"type": "text", "text": contenus}]
            if message["role"] == "user":
                passage += 1
                titre = "Ce qui lui est envoyé" if passage == 1 else \
                    f"Passage {passage} : les résultats d'outils qui lui sont renvoyés"
            else:
                titre = f"Passage {passage} : ce que le modèle répond"
            lignes += [f"## {titre}", ""]
            for bloc in contenus:
                lignes += _contenu(bloc) + [""]

        if texte_final is not None:
            lignes += ["## Sa réponse finale", "", _bloc_de_code(texte_final), ""]
        fichier.write_text("\n".join(lignes), encoding="utf-8")
        return fichier
    except Exception as erreur:  # noqa: BLE001 - une trace ratée ne casse jamais un appel
        LOG.warning("Trace de l'appel %s impossible : %s", id_appel, erreur)
        return None
