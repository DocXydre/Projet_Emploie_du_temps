"""Le dossier du coach : un fichier par chapitre, dans le dépôt        (COA-8)

Changer une règle sportive change le comportement du coach : c'est du code, et
c'est versionné comme tel. Le dossier ne nomme personne et ne décrit aucun cas
personnel : ce qui concerne une personne vit en base.

DOS-1 à DOS-6 : le coach ne reçoit pas tout le dossier à chaque appel. Le socle
part toujours, en entier. Le reste est découpé en paquets (`coach/paquets.json`),
et chaque paquet part soit en résumé (`coach/dossier/resumes/<code>.md`), soit en
complet, soit pas du tout. Ce qui manque se lit avec `lire_chapitre`.
"""

import hashlib
import json
import re
from functools import lru_cache
from pathlib import Path

from api.config import configuration

DETAILS = ("resume", "complet")

_NUMERO = re.compile(r"^\d{1,2}\.\d{1,2}$")


def racine() -> Path:
    choisie = configuration().coach_dossier
    if choisie:
        return Path(choisie)
    return Path(__file__).resolve().parents[2] / "coach" / "dossier"


@lru_cache
def chapitres() -> dict[str, str]:
    """Le texte de chaque chapitre, par son numéro. Lu une fois."""
    dossier = racine()
    textes = {}
    for fichier in sorted(dossier.glob("*.md")):
        if _NUMERO.match(fichier.stem):
            textes[fichier.stem] = fichier.read_text(encoding="utf-8")
    return textes


@lru_cache
def reglage_des_paquets() -> dict:
    """`coach/paquets.json` : le socle, les paquets, et ce que chaque moment joint."""
    fichier = racine().parent / "paquets.json"
    if not fichier.exists():
        return {"socle": [], "paquets": {}, "moments": {}, "disciplines": {},
                "detail_discipline": {}}
    return json.loads(fichier.read_text(encoding="utf-8"))


def socle() -> tuple[str, ...]:
    """DOS-1 : les chapitres qui partent à chaque appel, en entier."""
    return tuple(reglage_des_paquets().get("socle", []))


def paquets() -> dict[str, dict]:
    return {code: p for code, p in reglage_des_paquets().get("paquets", {}).items()
            if not code.startswith("_")}


@lru_cache
def resume(code: str) -> str | None:
    fichier = racine() / "resumes" / f"{code}.md"
    return fichier.read_text(encoding="utf-8").strip() if fichier.exists() else None


def texte_des_paquets(choix: dict[str, str]) -> str:
    """DOS-3 : les paquets choisis pour cet appel, chacun en résumé ou en complet.

    L'ordre est celui du fichier de réglage, pour qu'un même choix donne
    toujours le même texte, et se relise depuis le cache du fournisseur.
    """
    tous = paquets()
    retenus = [(code, choix[code]) for code in tous if choix.get(code) in DETAILS]
    deja = set(socle())
    morceaux = []
    if retenus:
        lignes = ", ".join(f"{code} ({'résumé' if d == 'resume' else 'complet'})"
                           for code, d in retenus)
        morceaux.append(
            "# Le dossier joint à cet appel\n\nPaquets joints : " + lignes + ". Un résumé "
            "garde les règles et les chiffres qui décident, pas le détail : quand il te "
            "faut un tableau, une liste d'exercices ou un plan complet, lis le chapitre "
            "avec `lire_chapitre`. Les paquets absents se lisent de la même façon.")
    else:
        morceaux.append(
            "# Le dossier joint à cet appel\n\nSeul le socle est joint. Lis avec "
            "`lire_chapitre` le chapitre dont tu as besoin (les numéros sont dans le "
            "sommaire).")
    for code, detail in retenus:
        if detail == "resume" and resume(code):
            morceaux.append(resume(code))
            continue
        for numero in tous[code].get("chapitres", []):
            if numero in deja or numero not in chapitres():
                continue
            deja.add(numero)
            morceaux.append(chapitres()[numero])
    return "\n\n---\n\n".join(m.strip() for m in morceaux if m)


@lru_cache
def sommaire() -> str:
    fichier = racine() / "sommaire.md"
    return fichier.read_text(encoding="utf-8") if fichier.exists() else ""


def chapitre(numero: str) -> str | None:
    """Un chapitre, ou None s'il n'existe pas. « 4.5 », pas un chemin."""
    numero = (numero or "").strip()
    if not _NUMERO.match(numero):
        return None
    return chapitres().get(numero)


@lru_cache
def consigne() -> str:
    """Le cadre de travail du coach dans l'application : `coach/consigne.md`.

    Il vit dans le dépôt, à côté du dossier : le changer change le comportement
    du coach, et demande de rejouer les scénarios (COA-14).
    """
    fichier = racine().parent / "consigne.md"
    return fichier.read_text(encoding="utf-8").strip() if fichier.exists() else ""


@lru_cache
def base() -> str:
    """La partie fixe de la consigne : sommaire, puis les chapitres du socle.

    Identique d'un appel à l'autre, au caractère près : c'est ce qui permet au
    fournisseur de la relire depuis son cache.
    """
    morceaux = [sommaire()]
    morceaux += [chapitres()[n] for n in socle() if n in chapitres()]
    return "\n\n---\n\n".join(m.strip() for m in morceaux if m)


@lru_cache
def version() -> str:
    """CAR-6 : l'empreinte du dossier, notée dans chaque échange.

    Calculée sur le contenu plutôt que lue dans git : l'image Docker n'embarque
    pas l'historique, et deux commits qui ne touchent pas au dossier donnent
    ainsi la même version.
    """
    empreinte = hashlib.sha256()
    for numero, texte in sorted(chapitres().items()):
        empreinte.update(numero.encode())
        empreinte.update(texte.encode("utf-8"))
    empreinte.update(sommaire().encode("utf-8"))
    empreinte.update(consigne().encode("utf-8"))
    empreinte.update(json.dumps(reglage_des_paquets(), sort_keys=True).encode("utf-8"))
    for code in sorted(paquets()):
        empreinte.update((resume(code) or "").encode("utf-8"))
    return empreinte.hexdigest()[:12]


def oublier_le_cache() -> None:
    """Pour les tests, et pour relire un dossier modifié sans redémarrer."""
    for fonction in (chapitres, sommaire, consigne, base, version, reglage_des_paquets,
                     resume):
        fonction.cache_clear()
