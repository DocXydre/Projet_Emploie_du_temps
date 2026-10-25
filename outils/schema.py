"""Le schéma de la base, dessiné depuis la base elle-même : sql/SCHEMA.md

    python -m outils.schema              réécrit sql/SCHEMA.md
    python -m outils.schema --verifier   dit seulement s'il est à jour

Le dessin se lit dans le catalogue de PostgreSQL : les tables, leurs clés
primaires et leurs clés étrangères, telles que les migrations les ont faites.
Il ne peut donc pas mentir sur le schéma, seulement prendre du retard, et
tests/test_schema.py le refuse dans ce cas.

Une table par domaine, un diagramme par domaine : soixante-dix tables sur un
seul dessin ne se liraient pas. Un lien se dessine une fois, dans le domaine de
la table qui porte la clé ; la table rejointe, si elle est d'un autre domaine,
apparaît par son seul nom. Presque tout pointe vers `utilisateur` : ces liens-là
ne se dessinent que dans le domaine du foyer, la colonne restant marquée FK.
Une table neuve doit être rangée dans DOMAINES.
"""

import sys
from pathlib import Path

import psycopg

from api.config import configuration

FICHIER = Path(__file__).resolve().parent.parent / "sql" / "SCHEMA.md"

DOMAINES: dict[str, tuple[str, list[str]]] = {
    "foyer": ("Le foyer, les comptes et leurs accès", [
        "utilisateur", "foyer", "invitation", "appareil", "session_appareil",
        "cle_mcp", "session_mcp", "fournisseur_modele", "tarif_modele"]),
    "planning": ("Le planning : sources, occupations, absences, trajets", [
        "source", "occupation", "conflit", "absence", "allegement", "calendrier",
        "trajet", "proposition", "courriel"]),
    "taches": ("Les tâches de la maison et leurs occurrences", [
        "tache", "type_tache", "occurrence", "enchainement", "remplacement",
        "accompagnement", "notification", "passage", "description_tache",
        "verification_tache"]),
    "sport": ("Le sport : lieux, plan, séances, exercices", [
        "lieu_sport", "discipline_lieu", "ouverture", "fermeture", "tache_lieu",
        "profil", "depistage", "limitation", "objectif", "pause", "plan",
        "plan_semaine", "seance", "seance_exercice", "exercice",
        "exercice_alternative", "exercice_interdit", "serie_saisie", "bilan_seance",
        "ajustement", "invitation_sport", "fenetre_mesure", "mesure"]),
    "sante": ("La santé, envoyée par l'iPhone", [
        "sante_jour", "sommeil_phase", "echantillon_sante", "grandeur_sante",
        "activite_sante", "activite_segment", "activite_serie", "activite_trace"]),
    "hal": ("HAL : appels au modèle, mémoire, demandes", [
        "demarrage_coach", "appel_coach", "echange", "memoire_coach", "memoire_foyer",
        "note_coach", "trace_coach", "demande"]),
    "lieux": ("Les lieux, la position, la soirée et la météo", [
        "lieu_connu", "lieu_de_chacun", "description_lieu", "trajet_calcule", "presence",
        "position_actuelle", "question_presence", "cours_annule", "soiree", "meteo_heure",
        "meteo_activite"]),
    "journal": ("Le journal et l'administration du serveur", [
        "evenement", "curseur", "alerte_admin", "erreur_recente"]),
}

TABLES = """
    SELECT c.relname AS nom, obj_description(c.oid) AS commentaire
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r'
     ORDER BY c.relname
"""

COLONNES = """
    SELECT c.relname AS tableau, a.attname AS colonne, format_type(a.atttypid, NULL) AS type,
           EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = c.oid AND k.contype = 'p'
                      AND a.attnum = ANY (k.conkey)) AS primaire,
           EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = c.oid AND k.contype = 'f'
                      AND a.attnum = ANY (k.conkey)) AS etrangere
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     WHERE n.nspname = 'public' AND c.relkind = 'r'
     ORDER BY c.relname, a.attnum
"""

LIENS = """
    SELECT DISTINCT enfant.relname AS enfant, parent.relname AS parent,
           string_agg(a.attname, ', ' ORDER BY a.attnum) AS colonnes
      FROM pg_constraint k
      JOIN pg_class enfant ON enfant.oid = k.conrelid
      JOIN pg_class parent ON parent.oid = k.confrelid
      JOIN pg_namespace n ON n.oid = enfant.relnamespace
      JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey)
     WHERE k.contype = 'f' AND n.nspname = 'public'
     GROUP BY k.oid, enfant.relname, parent.relname
     ORDER BY 1, 2, 3
"""


def _type(texte: str) -> str:
    """Un type de PostgreSQL en un mot, comme mermaid les accepte."""
    return texte.split("(")[0].replace(" ", "_").replace("[]", "_liste")


def lire(conn) -> tuple[dict, dict, list]:
    tables = {t["nom"]: t["commentaire"] for t in conn.execute(TABLES).fetchall()}
    colonnes: dict[str, list[dict]] = {}
    for ligne in conn.execute(COLONNES).fetchall():
        colonnes.setdefault(ligne["tableau"], []).append(ligne)
    return tables, colonnes, conn.execute(LIENS).fetchall()


def non_rangees(tables: dict) -> set[str]:
    rangees = {t for _, membres in DOMAINES.values() for t in membres}
    return set(tables) - rangees


def dessiner(tables: dict, colonnes: dict, liens: list) -> str:
    domaine_de = {t: d for d, (_, membres) in DOMAINES.items() for t in membres}
    morceaux = [
        "# Le schéma de la base\n",
        "Généré par `python -m outils.schema` depuis le catalogue de PostgreSQL, "
        "après les migrations : ne pas le modifier à la main. Chaque table montre sa "
        "clé primaire (PK) et ses clés étrangères (FK) ; une table d'un autre domaine "
        "n'apparaît que par son nom. Les liens vers `utilisateur`, que presque toutes "
        "les tables portent, ne sont dessinés que dans le premier diagramme.\n",
        f"{len(tables)} tables, {len(liens)} clés étrangères.\n",
    ]
    for domaine, (titre, membres) in DOMAINES.items():
        lignes = ["erDiagram"]
        for lien in liens:
            if domaine_de.get(lien["enfant"]) != domaine:
                continue
            if lien["parent"] == "utilisateur" and domaine != "foyer":
                continue
            lignes.append(f'    {lien["parent"]} ||--o{{ {lien["enfant"]} : '
                          f'"{lien["colonnes"]}"')
        # Les tables voisines ne se déclarent pas : leurs liens suffisent à les
        # faire paraître, par leur seul nom.
        for table in membres:
            cles = [c for c in colonnes.get(table, []) if c["primaire"] or c["etrangere"]]
            if not cles:
                lignes.append(f"    {table}")
                continue
            lignes.append(f"    {table} {{")
            for c in cles:
                marque = ",".join(m for m, oui in (("PK", c["primaire"]), ("FK", c["etrangere"]))
                                  if oui)
                lignes.append(f"        {_type(c['type'])} {c['colonne']} {marque}")
            lignes.append("    }")
        description = "\n".join(
            f"- `{t}` : {tables[t].splitlines()[0].strip()}" if tables.get(t) else f"- `{t}`"
            for t in membres)
        morceaux.append(f"## {titre}\n\n```mermaid\n" + "\n".join(lignes)
                        + f"\n```\n\n{description}\n")
    return "\n".join(morceaux)


def generer(conn) -> str:
    tables, colonnes, liens = lire(conn)
    seules = non_rangees(tables)
    if seules:
        raise SystemExit(f"Tables à ranger dans DOMAINES (outils/schema.py) : "
                         f"{', '.join(sorted(seules))}")
    return dessiner(tables, colonnes, liens)


def main() -> int:
    with psycopg.connect(configuration().url_base,
                         row_factory=psycopg.rows.dict_row) as conn:
        texte = generer(conn)
    if "--verifier" in sys.argv:
        a_jour = FICHIER.exists() and FICHIER.read_text() == texte
        print("sql/SCHEMA.md est à jour." if a_jour
              else "sql/SCHEMA.md n'est plus à jour : python -m outils.schema")
        return 0 if a_jour else 1
    FICHIER.write_text(texte)
    print(f"Écrit : {FICHIER}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
