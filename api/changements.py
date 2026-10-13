"""Annoncer les changements du planning, avec leur raison                 (NOT-17)

« L'aspirateur passe à jeudi : absence mercredi. » C'est ce qui remplace
« /pourquoi » au quotidien : on n'a plus à demander, la raison arrive avec le
changement.

Le journal sait déjà tout (JRN) : ce qui a bougé, dans quelle action, et ce qui
l'a déclenché. Ce module le relit à mesure, et écrit une notification par
personne touchée et par action : les changements d'une même action partent
ensemble.

Ce qui ne s'annonce pas :
- ce qu'on a fait soi-même : on le sait ;
- une tâche nouvelle, placée par le moteur : le bilan du matin la montre ;
- ce qui est loin : au-delà de la fenêtre de stabilité (PLA-5), le planning
  peut encore bouger sans que personne n'ait à le savoir ;
- le cours ordinaire des choses : une tâche annoncée par le bilan, reportée ou
  oubliée par le report de minuit, qui a ses propres messages.

Une tâche faite par l'autre s'annonce toujours, avec son nom.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from api import journal
from api.base import executer, lister, un_seul
from api.config import configuration

MAX_LIGNES = 5
MAX_RAISON = 120
# Une action encore en cours ne se raconte pas à moitié.
DELAI_SECONDES = 30
LOT = 2000


def _debut(intervalle: str | None) -> datetime | None:
    debut, _ = journal._bornes(intervalle)
    return debut


def annoncable(evenement: dict, maintenant: datetime, horizon: datetime) -> bool:
    if evenement["objet"] != "occurrence" or evenement["technique"]:
        return False
    avant, apres = evenement["avant"], evenement["apres"]
    if avant is None:
        return False

    if apres is None:
        if avant.get("statut") not in ("planifiee", "notifiee"):
            return False
        debut = _debut(avant.get("creneau"))
        return debut is not None and maintenant - timedelta(days=1) <= debut <= horizon

    statut, ancien = apres.get("statut"), avant.get("statut")
    if statut != ancien:
        if statut == "faite":
            return True
        if statut in ("notifiee", "reportee"):
            return False
        if statut == "abandonnee" and evenement["acteur"] == "ordonnanceur":
            return False

    debuts = [_debut(etat.get("creneau")) for etat in (avant, apres)]
    debuts = [d for d in debuts if d is not None]
    if not debuts:
        # « N'a plus de créneau » : on le dit si la tâche était dans la fenêtre.
        return False
    return any(maintenant - timedelta(days=1) <= d <= horizon for d in debuts)


def _touches(evenement: dict) -> set[int]:
    ids = set()
    for etat in (evenement["avant"], evenement["apres"]):
        if etat and etat.get("id_utilisateur") is not None:
            ids.add(int(etat["id_utilisateur"]))
    return ids


def _cause_au_creneau(evenement: dict, noms: dict[int, str]) -> str | None:
    """Ce qui occupe maintenant l'ancien créneau de l'ancien titulaire.

    L'absence et le cours se déclarent dans une action, le placement qui en
    tire les conséquences tourne dans une autre. Le journal ne relie pas les
    deux : on regarde donc ce qui a pris la place de la tâche.
    """
    avant, apres = evenement["avant"] or {}, evenement["apres"] or {}
    if apres.get("statut") in ("faite", "abandonnee"):
        return None
    qui, creneau = avant.get("id_utilisateur"), avant.get("creneau")
    if qui is None or not creneau:
        return None
    ligne = un_seul(
        """
        SELECT genre, libelle, fin FROM (
            SELECT 1 AS rang, 'absence' AS genre, lieu AS libelle,
                   upper(periode) - INTERVAL '1 second' AS fin FROM absence
             WHERE id_utilisateur = %(u)s AND periode && %(c)s::TSTZRANGE
            UNION ALL
            SELECT 2, type, libelle, NULL FROM occupation
             WHERE id_utilisateur = %(u)s AND periode && %(c)s::TSTZRANGE
               AND type <> 'sommeil'
        ) c ORDER BY rang LIMIT 1
        """,
        {"u": int(qui), "c": creneau})
    if ligne is None:
        return None
    nom, debut = noms.get(int(qui), "quelqu'un"), _debut(creneau)
    jour = journal.jour_en_clair(debut) if debut else ""
    if ligne["genre"] == "absence":
        # Une absence dure souvent plusieurs jours : on dit jusqu'à quand.
        fin = f" jusqu'au {journal.jour_en_clair(ligne['fin'])}" if ligne["fin"] else ""
        return f"absence de {nom}{fin}"
    if ligne["genre"] == "cours":
        return f"cours de {nom} {jour} ({ligne['libelle']})"
    if ligne["genre"] == "travail":
        return f"{nom} travaille {jour}".rstrip()
    return f"{ligne['libelle']}, pour {nom} {jour}".rstrip()


def raison(lignes: list[dict], siens: list[dict], noms: dict[int, str],
           noms_par_pseudo: dict[str, str]) -> str | None:
    """La cause, dans cet ordre : ce qui a déclenché l'action, ce qui a pris la
    place de la tâche, le geste de quelqu'un, et à défaut d'où vient l'action."""
    declencheurs = [e for e in lignes
                    if e["objet"] not in ("occurrence", "notification")
                    and not e["technique"] and not journal._routine(e)]
    texte = declencheurs[0]["phrase"] if declencheurs else None

    if texte is None:
        texte = next((c for c in (_cause_au_creneau(e, noms) for e in siens) if c), None)

    if texte is None:
        gestes = [e for e in lignes if e["objet"] == "occurrence"
                  and (e["apres"] or {}).get("statut") == "faite"
                  and (e["avant"] or {}).get("statut") != "faite"]
        if gestes:
            # « Faite par Lorette » dit déjà qui, et pourquoi.
            if all(e in gestes for e in siens):
                return None
            texte = gestes[0]["phrase"]

    if texte is None:
        acteur, origine = lignes[0]["acteur"], lignes[0]["origine"]
        texte = (f"changé par {noms_par_pseudo[acteur]}" if acteur in noms_par_pseudo
                 else journal._origine(origine) or None)
    if not texte:
        return None
    return texte if len(texte) <= MAX_RAISON else texte[:MAX_RAISON - 1].rstrip() + "…"


def _curseur() -> int:
    ligne = un_seul("SELECT dernier FROM curseur WHERE nom = 'changements'")
    if ligne is None:
        # Premier passage sans la migration : on part de maintenant.
        ligne = executer(
            """INSERT INTO curseur (nom, dernier)
               SELECT 'changements', COALESCE(max(id_evenement), 0) FROM evenement
               ON CONFLICT (nom) DO UPDATE SET dernier = curseur.dernier
               RETURNING dernier""")
    return int(ligne["dernier"]) if ligne else 0


def annoncer() -> int:
    """Un passage : lit le journal depuis la dernière fois, et écrit les annonces."""
    depuis = _curseur()
    evenements = lister(
        """
        SELECT id_evenement, quand, operation, acteur, origine, objet, id_objet,
               libelle, avant, apres, detail, technique
          FROM evenement
         WHERE id_evenement > %(depuis)s
           AND quand < now() - make_interval(secs => %(delai)s)
         ORDER BY id_evenement
         LIMIT %(lot)s
        """,
        {"depuis": depuis, "delai": DELAI_SECONDES, "lot": LOT},
    )
    if not evenements:
        return 0

    comptes = lister("SELECT id_utilisateur, pseudo, nom, actif FROM utilisateur")
    noms = {c["id_utilisateur"]: c["nom"] for c in comptes}
    pseudos = {c["id_utilisateur"]: c["pseudo"] for c in comptes}
    actifs = {c["id_utilisateur"] for c in comptes if c["actif"]}
    noms_par_pseudo = {c["pseudo"]: c["nom"] for c in comptes}

    fuseau = journal._fuseau()
    maintenant = datetime.now(fuseau)
    horizon = maintenant + timedelta(days=configuration().stabilite_jours)

    par_action: dict[str, list[dict]] = {}
    for evenement in evenements:
        evenement["phrase"] = journal.phrase(evenement, noms)
        par_action.setdefault(evenement["operation"], []).append(evenement)

    ecrites = 0
    for operation, lignes in par_action.items():
        acteur = lignes[0]["acteur"]
        pour: dict[int, list[dict]] = {}
        for evenement in lignes:
            if not annoncable(evenement, maintenant, horizon):
                continue
            for qui in _touches(evenement):
                if qui in actifs and pseudos.get(qui) != acteur:
                    pour.setdefault(qui, []).append(evenement)
        if not pour:
            continue

        for qui, siens in pour.items():
            siens.sort(key=journal._ordre_des_taches)
            cause = raison(lignes, siens, noms, noms_par_pseudo)
            texte = [e["phrase"] for e in siens[:MAX_LIGNES]]
            if len(siens) > MAX_LIGNES:
                reste = len(siens) - MAX_LIGNES
                texte.append(f"et {reste} autre{'s' if reste > 1 else ''}")
            if cause:
                texte.append(f"Pourquoi : {cause}")
            executer(
                """
                INSERT INTO notification (id_utilisateur, type, contenu, operation, id_occurrence)
                VALUES (%(u)s, 'changement', %(c)s, %(op)s,
                        (SELECT id_occurrence FROM occurrence WHERE id_occurrence = %(occ)s))
                """,
                {"u": qui, "c": "\n".join(texte), "op": operation,
                 # Une seule tâche : la notification ouvre la tâche. Plusieurs :
                 # l'Historique, sur l'action (NOT-19).
                 "occ": siens[0]["id_objet"] if len(siens) == 1 else None},
            )
            ecrites += 1

    executer("UPDATE curseur SET dernier = %(d)s WHERE nom = 'changements'",
             {"d": evenements[-1]["id_evenement"]})
    return ecrites
