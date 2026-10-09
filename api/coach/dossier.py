"""Le dossier du coach : un fichier par chapitre, dans le dépôt        (COA-8)

Changer une règle sportive change le comportement du coach : c'est du code, et
c'est versionné comme tel. Le dossier ne nomme personne et ne décrit aucun cas
personnel : ce qui concerne une personne vit en base.
"""

import hashlib
import re
from functools import lru_cache
from pathlib import Path

from api.config import configuration

# COA-3 : les six chapitres qui partent à chaque appel. Les autres se lisent à
# la demande, par l'outil `lire_chapitre`.
CHAPITRES_DE_BASE = ("1.1", "1.2", "2.4", "10.1", "10.2", "10.3")

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
    """La partie fixe de la consigne : sommaire, puis les chapitres de base.

    Identique d'un appel à l'autre, au caractère près : c'est ce qui permet au
    fournisseur de la relire depuis son cache.
    """
    morceaux = [sommaire()]
    morceaux += [chapitres()[n] for n in CHAPITRES_DE_BASE if n in chapitres()]
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
    return empreinte.hexdigest()[:12]


def oublier_le_cache() -> None:
    """Pour les tests, et pour relire un dossier modifié sans redémarrer."""
    for fonction in (chapitres, sommaire, consigne, base, version):
        fonction.cache_clear()
