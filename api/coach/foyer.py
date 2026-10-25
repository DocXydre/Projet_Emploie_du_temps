"""Le HAL du foyer : ce qui le distingue du HAL sport             (HDF, lot 16)

Le même module d'appel sert les deux HAL (`appel.py`). Ce fichier tient ce que
le HAL du foyer a en propre :

    sa consigne              coach/consigne_foyer.md, sans le dossier sportif
    son contexte             qui écrit, les membres, la mémoire du foyer
    sa mémoire               celle du foyer, commune aux membres         (HDF-4)
    ses outils               la lecture de la maison, les demandes, sa mémoire,
                             les lieux et les cours annulés (partie H)
    ses moments              « maison », la conversation ; « presence », les
                             questions qu'il pose de lui-même (POS-7, POS-8, POS-10)

HDF-3 : de l'autre membre, il ne lit que ce qu'il faut pour la maison. Les
outils de lecture qu'il reprend le font déjà (COA-15, MCP-11).
"""

from datetime import date
from functools import lru_cache
from pathlib import Path

from api.base import executer, lister, un_seul
from api.coach.clair import aujourd_hui, jour_en_clair, lundi_de, maintenant
from api.coach.outils import Outil, RefusOutil, _objet

MOMENTS = ("maison", "presence")

CONSIGNE = Path(__file__).resolve().parent.parent.parent / "coach" / "consigne_foyer.md"


@lru_cache
def consigne() -> str:
    return CONSIGNE.read_text(encoding="utf-8").strip()


def foyer_de(id_utilisateur: int) -> int | None:
    ligne = un_seul("SELECT foyer_de(%(u)s) AS f", {"u": id_utilisateur})
    return (ligne or {}).get("f")


def actif_pour(id_utilisateur: int) -> int | None:
    """HDF-1 : le foyer du compte, si son HAL du foyer est actif ; sinon None."""
    ligne = un_seul(
        """SELECT f.id_foyer FROM foyer f
            WHERE f.id_foyer = foyer_de(%(u)s) AND f.hal_actif""", {"u": id_utilisateur})
    return (ligne or {}).get("id_foyer")


# ---------------------------------------------------------------------------
# La mémoire du foyer                                                  (HDF-4)
# ---------------------------------------------------------------------------

def en_vigueur(id_foyer: int, niveau: str, periode: date | None = None) -> dict | None:
    return un_seul(
        """SELECT id_memoire, niveau, periode, texte, auteur, nom_auteur, quand,
                  longueur, limite
             FROM v_memoire_foyer
            WHERE id_foyer = %(f)s AND niveau = %(n)s
              AND periode IS NOT DISTINCT FROM %(p)s::DATE""",
        {"f": id_foyer, "n": niveau, "p": periode})


def etat_memoire(id_foyer: int) -> dict:
    lundi = lundi_de(aujourd_hui())
    precedentes = lister(
        """SELECT id_memoire, periode, texte, longueur, limite, quand
             FROM v_memoire_foyer
            WHERE id_foyer = %(f)s AND niveau = 'semaine' AND periode < %(l)s
              AND btrim(texte) <> ''
            ORDER BY periode DESC LIMIT 3""", {"f": id_foyer, "l": lundi})
    return {"globale": en_vigueur(id_foyer, "globale"),
            "semaines_passees": list(reversed(precedentes)),
            "semaine": en_vigueur(id_foyer, "semaine", lundi),
            "lundi": lundi}


def _taille(ligne: dict | None, niveau: str) -> str:
    longueur = (ligne or {}).get("longueur") or 0
    limite = (ligne or {}).get("limite") or {"globale": 4000, "semaine": 3000}[niveau]
    return f"({longueur}/{limite} caractères)"


def texte_memoire(id_foyer: int) -> str:
    e = etat_memoire(id_foyer)
    morceaux = ["# La mémoire du foyer",
                "Commune aux membres : chacun la lit et la corrige dans l'appli."]
    g = e["globale"]
    morceaux.append(f"## Ce qui dure {_taille(g, 'globale')}")
    morceaux.append((g or {}).get("texte") or "Vide pour l'instant.")
    for s in e["semaines_passees"]:
        morceaux.append(f"## La semaine du {jour_en_clair(s['periode'])}")
        morceaux.append(s["texte"])
    s = e["semaine"]
    morceaux.append(f"## La semaine en cours, depuis le {jour_en_clair(e['lundi'])} "
                    f"{_taille(s, 'semaine')}")
    morceaux.append((s or {}).get("texte") or "Rien encore cette semaine.")
    return "\n\n".join(morceaux)


def ecrire(id_foyer: int, niveau: str, texte: str, auteur: str,
           id_auteur: int | None = None, periode: date | None = None) -> int:
    ligne = executer(
        "SELECT ecrire_memoire_foyer(%(f)s, %(n)s, %(t)s, %(a)s, %(i)s, %(p)s) AS id",
        {"f": id_foyer, "n": niveau, "t": texte, "a": auteur, "i": id_auteur, "p": periode})
    return ligne["id"]


# ---------------------------------------------------------------------------
# Le contexte                                                    (COA-3, HDF-3)
# ---------------------------------------------------------------------------

def texte_contexte(id_utilisateur: int) -> str:
    id_foyer = foyer_de(id_utilisateur)
    membres = lister(
        """SELECT u.id_utilisateur, u.pseudo, u.nom,
                  u.id_utilisateur = f.id_administrateur AS administrateur
             FROM utilisateur u JOIN foyer f ON f.id_foyer = u.id_foyer
            WHERE u.id_foyer = %(f)s AND u.actif
            ORDER BY u.id_utilisateur""", {"f": id_foyer})
    moi = next((m for m in membres if m["id_utilisateur"] == id_utilisateur), None)
    lignes = ["# Le foyer"]
    if moi:
        lignes.append(f"Celui qui t'écrit : {moi['nom']} (pseudo {moi['pseudo']}).")
    autres = [f"{m['nom']} (pseudo {m['pseudo']}"
              + (", administrateur du foyer)" if m["administrateur"] else ")")
              for m in membres if m["id_utilisateur"] != id_utilisateur]
    lignes.append("Les autres membres : " + (", ".join(autres) if autres else "aucun."))
    if moi and moi["administrateur"]:
        lignes.append(f"{moi['nom']} administre le foyer.")
    # ADR-12, POS-5 : les lieux et la présence de celui qui écrit, de lui seul.
    from api import lieux
    return ("\n".join(lignes) + "\n\n" + texte_memoire(id_foyer) + "\n\n"
            + lieux.texte_pour_hal(id_utilisateur, "foyer"))


def origine_et_acteur(moment_: str) -> tuple[str, str]:
    """HDF-7 : l'opération d'un appel du HAL du foyer est sous l'acteur « hal_foyer »."""
    if moment_ in MOMENTS:
        return f"hal du foyer : {moment_}", "hal_foyer"
    return f"coach : {moment_}", "coach"


def moment(id_utilisateur: int, moment_: str = "maison") -> str:
    jour = maintenant()
    if moment_ == "presence":
        return "\n\n".join([
            "# Moment : presence",
            f"{jour_en_clair(jour.date())} {jour.year}, {jour:%H:%M}.",
            "Tu écris de toi-même : l'iPhone dit où est ce membre, et quelque chose "
            "demande sa confirmation. Pose la question qui suit, en une ou deux phrases, "
            "avec des réponses prêtes. Tu ne changes rien maintenant : sa réponse, dans la "
            "conversation, fera le geste."])
    return "\n\n".join([
        "# Moment : maison",
        f"{jour_en_clair(jour.date())} {jour.year}, {jour:%H:%M}.",
        "Un membre du foyer t'écrit. Une question : réponds-y, après avoir lu ce qu'il "
        "faut. Une demande de changement : fais le geste qui correspond, avec son motif "
        "en une phrase, puis dis ce qui a changé. Ce qui dure et sert la maison va dans "
        "la mémoire du foyer."])


# ---------------------------------------------------------------------------
# Ses outils                                                           (HDF-7)
# ---------------------------------------------------------------------------

def ecrire_memoire_foyer(u: int, a: dict) -> object:
    niveau = a.get("niveau")
    if niveau not in ("semaine", "globale"):
        raise RefusOutil("requete_invalide", "« niveau » vaut semaine ou globale")
    id_foyer = foyer_de(u)
    version = ecrire(id_foyer, niveau, a.get("texte") or "", "hal")
    return {"fait": f"mémoire {niveau} du foyer écrite", "version": version}


def ajouter_memoire_foyer(u: int, a: dict) -> object:
    ligne = (a.get("ligne") or "").strip()
    if not ligne:
        raise RefusOutil("requete_invalide", "« ligne » est vide")
    id_foyer = foyer_de(u)
    actuelle = en_vigueur(id_foyer, "semaine", lundi_de(aujourd_hui()))
    texte = ((actuelle or {}).get("texte") or "").rstrip()
    nouveau = (texte + "\n" if texte else "") + "- " + ligne.lstrip("- ")
    version = ecrire(id_foyer, "semaine", nouveau, "hal")
    return {"fait": "ligne ajoutée à la mémoire du foyer", "version": version,
            "longueur": len(nouveau)}


OUTILS_PROPRES: tuple[Outil, ...] = (
    Outil("ecrire_memoire_foyer", "memoire_foyer",
          "Réécrit en entier un étage de la mémoire du foyer, en repartant du texte "
          "actuel. « semaine » : 3 000 caractères, pour corriger ou condenser. "
          "« globale » : 4 000 caractères, ce qui dure (une habitude, une contrainte, "
          "une décision du foyer). Rien de personnel ni de sportif.",
          _objet({"niveau": {"type": "string", "enum": ["semaine", "globale"]},
                  "texte": {"type": "string"}}, ["niveau", "texte"]),
          ecrire_memoire_foyer),
    Outil("ajouter_memoire_foyer", "memoire_foyer",
          "Ajoute une ligne à la mémoire du foyer de cette semaine, sans la réécrire : "
          "une habitude dite, une décision et sa raison.",
          _objet({"ligne": {"type": "string"}}, ["ligne"]), ajouter_memoire_foyer),
)


def annuler_cours(u: int, a: dict) -> object:
    """POS-11 : un cours dit annulé ne revient plus, et libère son créneau."""
    from api import ordonnanceur
    ligne = executer("SELECT annuler_cours(%(u)s, %(o)s) AS c",
                     {"u": u, "o": a.get("id_occupation")})
    replacees = ordonnanceur.placer()
    return {"fait": "cours annulé", "cours": ligne["c"], "occurrences_replacees": replacees}


OUTIL_ANNULER_COURS = Outil(
    "annuler_cours", "gestes",
    "Retire du planning un cours que l'utilisateur dit annulé (id_occupation) : il ne "
    "reviendra pas à la collecte suivante, et son créneau se libère. À n'utiliser que "
    "s'il te le dit dans ce message.",
    _objet({"id_occupation": {"type": "integer"}}, ["id_occupation"]), annuler_cours)

# Ce que le HAL du foyer lit : la maison, et le planning de celui qui écrit.
LECTURES = ("lire_aujourdhui", "lire_taches", "lire_occurrences", "lire_absences",
            "lire_conflits", "lire_planning")


def outils_du_moment(moment_: str) -> list[Outil]:
    """HDF-7, COA-5 : les outils du moment « maison »."""
    from api import demandes
    from api.serveur_mcp import catalogue
    if moment_ not in MOMENTS:
        raise ValueError(f"Moment inconnu pour le HAL du foyer : {moment_}")
    from api.coach import outils_lieux
    lectures = [catalogue.EXTERNE[nom] for nom in LECTURES]
    lieux = list(outils_lieux.outils("hal_foyer"))
    if moment_ == "presence":
        # Il demande ; la réponse, au moment « maison », fera le geste.
        return [*lectures, *lieux]
    # ACT-1 : les gestes de la maison, faits à la demande de celui qui écrit.
    return [*lectures, *demandes.OUTILS_GESTES_MAISON, OUTIL_ANNULER_COURS,
            *OUTILS_PROPRES, *lieux]


def office(id_utilisateur: int) -> str:
    """COA-28 : la journée de la maison, jointe d'office au premier message."""
    import json

    from api.coach.clair import clair
    from api.serveur_mcp import catalogue
    try:
        lu = catalogue.lire_aujourdhui(id_utilisateur, {})
    except Exception:  # noqa: BLE001 - une lecture manquée se refait par outil
        return ""
    return ("# Données lues pour toi à l'ouverture de l'appel\n"
            "Elles sont à jour : ne les relis pas avec tes outils.\n\n"
            "## La journée de la maison (lire_aujourdhui)\n"
            + json.dumps(clair(lu), ensure_ascii=False))
