"""Les vérifications du HAL du foyer                         (VER-3 à VER-9, lot 18)

Deux moments, sans personne qui écrit :

    « verification »   la file : ce qui a bougé sur une tâche décrite, ou ce qui
                       est tombé sur son jour. Au plus un appel par quart
                       d'heure, et aucun si la file est vide (VER-4).
    « semaine »        une fois par semaine, au jour et à l'heure du foyer, le
                       lundi à 6h30 par défaut : toutes les tâches décrites et
                       leurs quatre semaines (VER-5). Aucun appel sans tâche
                       décrite.

L'appel passe par la chaîne de l'administrateur du foyer (HDF-6). Il échoue :
rien ne bouge, la file reste pour le suivant (VER-9).
"""

import json
import logging
from datetime import timedelta

from api.base import executer, lister, un_seul
from api.coach.clair import clair, maintenant

LOG = logging.getLogger(__name__)


def _foyers() -> list[dict]:
    """Les foyers ouverts dont le HAL est actif, avec leur administrateur."""
    return lister(
        """SELECT f.id_foyer, f.id_administrateur, f.verification_jour,
                  f.verification_heure, f.semaine_relue_le
             FROM foyer f
             JOIN utilisateur u ON u.id_utilisateur = f.id_administrateur AND u.actif
            WHERE f.ferme_le IS NULL AND f.hal_actif""")


def file_en_attente() -> list[dict]:
    """VER-3 : ce qui attend d'être relu, occurrence par occurrence ou tâche entière."""
    return lister(
        """SELECT v.id_verification, v.raison, v.cree_le,
                  COALESCE(o.id_tache, v.id_tache) AS id_tache, t.libelle AS tache,
                  d.texte AS description, v.id_occurrence,
                  o.statut, o.debut, o.fin, o.echeance_min, o.echeance_max,
                  o.assigne_a AS pour, o.epinglee_par, o.motif
             FROM verification_tache v
             LEFT JOIN v_occurrence o ON o.id_occurrence = v.id_occurrence
             JOIN tache t ON t.id_tache = COALESCE(o.id_tache, v.id_tache)
             JOIN v_description_tache d ON d.id_tache = t.id_tache
            WHERE v.traitee_le IS NULL AND t.active
            ORDER BY v.cree_le, v.id_verification""")


def _clore(ids: list[int]) -> None:
    if ids:
        executer("UPDATE verification_tache SET traitee_le = now() "
                 "WHERE id_verification = ANY (%(i)s) AND traitee_le IS NULL", {"i": ids})


RAISONS = {"creee": "le moteur l'a créée", "deplacee": "le moteur l'a déplacée",
           "a_placer": "le moteur ne lui a pas trouvé de place",
           "occupation": "un créneau pris est tombé sur son jour",
           "absence": "une absence a été déclarée, changée ou retirée",
           "conflit": "un conflit est tombé sur son jour",
           "repartition": "elle a changé de mains",
           "description": "sa description vient d'être reprise"}


def _texte_de_la_file(lignes: list[dict]) -> str:
    morceaux = ["# À relire"]
    for ligne in lignes:
        morceaux.append(json.dumps(clair({
            "id_tache": ligne["id_tache"], "tache": ligne["tache"],
            "description": ligne["description"], "id_occurrence": ligne["id_occurrence"],
            "pourquoi": RAISONS.get(ligne["raison"], ligne["raison"]),
            "statut": ligne["statut"], "debut": ligne["debut"], "fin": ligne["fin"],
            "au_plus_tot": ligne["echeance_min"], "au_plus_tard": ligne["echeance_max"],
            "pour": ligne["pour"], "epinglee_par": ligne["epinglee_par"], "motif": ligne["motif"],
        }), ensure_ascii=False))
    return "\n".join(morceaux)


def _appeler(id_administrateur: int, moment: str, precision: str) -> bool:
    from api.coach import appel
    demande = appel.Demande(id_utilisateur=id_administrateur, moment=moment,
                            declencheur="ordonnanceur", precision=precision, hal="foyer",
                            # Rien à annoncer à l'administrateur : les personnes
                            # concernées sont prévenues par placement (VER-6).
                            deja_affichee=True)
    try:
        appel.appeler_coach(demande)
        return True
    except (appel.CoachInactif, appel.FoyerInactif):
        return False
    except appel.EchecAppel as echec:
        # VER-9 : rien ne bouge, la file attend l'appel suivant.
        LOG.warning("Vérification %s sans réponse de HAL : %s", moment, echec.motif)
        return False


def verifier_la_file() -> dict:
    """VER-4 : un appel pour toute la file, s'il y a quelque chose à relire."""
    lignes = file_en_attente()
    # Ce qui n'a plus de description, ou dont la tâche est arrêtée, ne se relit plus.
    executer("""UPDATE verification_tache v SET traitee_le = now()
                 WHERE v.traitee_le IS NULL
                   AND NOT EXISTS (SELECT 1 FROM v_description_tache d
                                     JOIN tache t ON t.id_tache = d.id_tache AND t.active
                                    WHERE d.id_tache = COALESCE(
                                          (SELECT o.id_tache FROM occurrence o
                                            WHERE o.id_occurrence = v.id_occurrence),
                                          v.id_tache))""")
    if not lignes:
        return {"relues": 0}
    relues = 0
    for f in _foyers():
        if _appeler(f["id_administrateur"], "verification", _texte_de_la_file(lignes)):
            _clore([ligne["id_verification"] for ligne in lignes])
            relues = len(lignes)
        break  # FOY-10 : un seul foyer pour l'instant.
    return {"relues": relues}


def semaine_due(foyer: dict, quand=None) -> bool:
    """VER-5 : le jour et l'heure du foyer sont passés, et pas encore cette semaine."""
    quand = quand or maintenant()
    lundi = quand.date() - timedelta(days=quand.isoweekday() - 1)
    jour = lundi + timedelta(days=foyer["verification_jour"] - 1)
    if (quand.date(), quand.time()) < (jour, foyer["verification_heure"]):
        return False
    return foyer["semaine_relue_le"] is None or foyer["semaine_relue_le"] < jour


def _texte_de_la_semaine() -> str | None:
    taches = lister(
        """SELECT t.id_tache, t.libelle, t.revient, d.texte AS description
             FROM tache t JOIN v_description_tache d ON d.id_tache = t.id_tache
            WHERE t.active ORDER BY t.libelle""")
    if not taches:
        return None
    occurrences = lister(
        """SELECT o.id_occurrence, o.id_tache, o.statut, o.debut, o.fin, o.echeance_min,
                  o.echeance_max, o.assigne_a AS pour, o.epinglee_par, o.motif
             FROM v_occurrence o
            WHERE o.id_tache = ANY (%(t)s)
              AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
              AND COALESCE(o.debut, o.echeance_min) < now() + INTERVAL '28 days'
            ORDER BY COALESCE(o.debut, o.echeance_min)""",
        {"t": [t["id_tache"] for t in taches]})
    morceaux = ["# Les tâches décrites, et leurs quatre semaines"]
    for t in taches:
        t["occurrences"] = [o for o in occurrences if o["id_tache"] == t["id_tache"]]
        morceaux.append(json.dumps(clair(t), ensure_ascii=False))
    return "\n".join(morceaux)


def verifier_la_semaine(quand=None) -> dict:
    """VER-5 : une fois par semaine, toutes les tâches décrites."""
    fait = 0
    for f in _foyers():
        if not semaine_due(f, quand):
            continue
        texte = _texte_de_la_semaine()
        # Sans tâche décrite, pas d'appel ; la semaine compte quand même comme lue.
        if texte is None or _appeler(f["id_administrateur"], "semaine", texte):
            executer("UPDATE foyer SET semaine_relue_le = %(j)s WHERE id_foyer = %(f)s",
                     {"j": (quand or maintenant()).date(), "f": f["id_foyer"]})
            if texte is not None:
                # La semaine a tout relu : la file en attente aussi.
                _clore([ligne["id_verification"] for ligne in file_en_attente()])
                fait += 1
    return {"semaines": fait}


def en_attente() -> int:
    ligne = un_seul("SELECT count(*)::INTEGER AS n FROM verification_tache "
                    "WHERE traitee_le IS NULL")
    return (ligne or {}).get("n", 0)
