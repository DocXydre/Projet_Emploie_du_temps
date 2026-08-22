"""De la confirmation d'achat à l'absence déclarée.

Le chemin est court et volontairement sans raccourci : un billet lu est
enregistré comme n'importe quel trajet, puis retenu par la même fonction que
celle du bot. Rien ne justifierait un second chemin d'écriture — c'est ainsi
qu'on se retrouve avec deux façons de créer une absence qui divergent.

Ce module ne parle ni à IMAP ni à la SNCF. Il reçoit des courriels bruts, déjà
récupérés, ce qui permet de rejouer une boîte entière dans les tests.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime

import psycopg

from api.base import executer, lister, un_seul
from api.collecteurs import courriel as lecteur
from api.collecteurs.courriel import NOMS_LISIBLES, Lecture, Segment
from api.collecteurs.sncf import GARES

LOG = logging.getLogger(__name__)

# Nom lisible d'une gare, pour que l'absence dise « Saint-Dié-des-Vosges » et
# non « SAINT_DIE ». Les gares lues dans les courriels ne sont pas toutes
# connues de Navitia : Lunéville sert de départ sans qu'on y cherche d'horaire.
NOMS = {**NOMS_LISIBLES, **{code: nom for code, (_, nom) in GARES.items()}}


def _deja_vu(identifiant: str) -> bool:
    return un_seul(
        "SELECT 1 AS vu FROM courriel WHERE identifiant = %(id)s",
        {"id": identifiant},
    ) is not None


def _consigner(lecture: Lecture, statut: str, motif: str | None,
               id_utilisateur: int | None = None,
               id_absence: int | None = None) -> None:
    """Garde trace, y compris des courriels dont on n'a rien su faire (R75)."""
    executer(
        """
        INSERT INTO courriel (identifiant, expediteur, sujet, recu_le, statut,
                              motif, reference, id_utilisateur, id_absence)
        VALUES (%(id)s, %(de)s, %(sujet)s, %(recu)s, %(statut)s, %(motif)s,
                %(ref)s, %(u)s, %(abs)s)
        ON CONFLICT (identifiant) DO NOTHING
        RETURNING id_courriel
        """,
        {
            "id": lecture.identifiant, "de": lecture.expediteur[:255],
            "sujet": lecture.sujet[:500], "recu": lecture.recu_le,
            "statut": statut, "motif": motif, "ref": lecture.reference,
            "u": id_utilisateur, "abs": id_absence,
        },
    )


def _enregistrer_segment(id_utilisateur: int, segment: Segment,
                         id_trajet_aller: int | None = None) -> int:
    ligne = executer(
        """
        INSERT INTO trajet (id_utilisateur, sens, periode, origine, destination,
                            resume, id_trajet_aller)
        VALUES (%(u)s, %(sens)s, tstzrange(%(d)s, %(a)s, '[)'),
                %(o)s, %(dest)s, 'Billet acheté', %(aller)s)
        RETURNING id_trajet
        """,
        {
            "u": id_utilisateur, "sens": segment.sens,
            "d": segment.depart, "a": segment.arrivee,
            "o": NOMS.get(segment.depart_gare, segment.depart_gare),
            "dest": NOMS.get(segment.arrivee_gare, segment.arrivee_gare),
            "aller": id_trajet_aller,
        },
    )
    assert ligne is not None
    return ligne["id_trajet"]


def _quand(lecture: Lecture) -> datetime:
    """Date du voyage, ou à défaut celle du courriel.

    Sert uniquement à ordonner le traitement. Un courriel sans date exploitable
    passe en dernier : il ne déclenchera rien, autant qu'il ne s'intercale pas
    au milieu d'une série qui, elle, a un sens chronologique.
    """
    if lecture.segments:
        return lecture.segments[0].depart
    return lecture.recu_le or datetime.max.replace(tzinfo=UTC)


def _appliquer_sans_horaire(segment: Segment, id_utilisateur: int) -> dict:
    """Billet dont on connaît le jour, pas l'heure.                       (R80)

    Aucun appariement n'est nécessaire, et c'est ce qui rend la chose sûre :
    un billet vers la gare famille ouvre l'absence, un billet qui en revient
    la ferme. Les deux courriels arrivent d'ordinaire ensemble, mais rien
    n'oblige à ce qu'ils soient traités ensemble.

    Les bornes sont prises au jour entier, et volontairement à l'intérieur du
    voyage : l'absence commence au lendemain du départ et s'arrête au matin du
    retour. Sans horaire, ce sont les seules journées dont on soit certain —
    et se tromper dans ce sens fait faire une lessive de trop, non un retard.
    """
    jour = segment.depart.date()

    if segment.sens == "aller":
        try:
            cree = un_seul(
                "SELECT partir_maintenant(%(u)s, %(lieu)s, "
                "                         debut_jour(%(jour)s::DATE + 1)) AS id_absence",
                {"u": id_utilisateur, "lieu": NOMS.get(segment.arrivee_gare),
                 "jour": jour},
            )
        except psycopg.Error as erreur:
            diag = erreur.diag.message_primary if erreur.diag else str(erreur)
            return {"statut": "refuse", "motif": diag}

        assert cree is not None
        return {"statut": "traite", "id_absence": cree["id_absence"]}

    ferme = un_seul(
        "SELECT terminer_absence(%(u)s, debut_jour(%(jour)s::DATE)) AS id_absence",
        {"u": id_utilisateur, "jour": jour},
    )
    if ferme is None or ferme["id_absence"] is None:
        # Le billet de retour d'un voyage qu'on n'a jamais enregistré : rien à
        # fermer, et rien d'anormal. Le noter traité évite d'y revenir.
        return {"statut": "traite", "motif": "Retour noté, aucune absence ouverte"}
    return {"statut": "traite", "id_absence": ferme["id_absence"]}


def _appliquer(lecture: Lecture, id_utilisateur: int) -> dict:
    """Crée les trajets du billet, puis l'absence qui en découle.

    Un billet peut contenir un aller seul, ou un aller et un retour. On ne
    traite pas le cas de deux allers : ce serait deux voyages, et les
    enregistrer comme un seul gèlerait le ménage entre les deux.
    """
    if len(lecture.segments) == 1 and lecture.segments[0].sans_horaire:
        return _appliquer_sans_horaire(lecture.segments[0], id_utilisateur)

    allers = [s for s in lecture.segments if s.sens == "aller"]
    retours = [s for s in lecture.segments if s.sens == "retour"]

    if len(retours) > 1:
        return {"statut": "illisible",
                "motif": f"{len(retours)} retours reconnus dans le même billet"}

    if not allers and len(retours) == 1:
        # Un retour acheté seul, ce qui arrive quand on part sans savoir quand
        # on rentre. Il ferme l'absence en cours, à son heure d'arrivée cette
        # fois — c'est le même geste que « /retour », déclenché par le billet.
        ferme = un_seul(
            "SELECT terminer_absence(%(u)s, %(quand)s) AS id_absence",
            {"u": id_utilisateur, "quand": retours[0].arrivee},
        )
        if ferme is None or ferme["id_absence"] is None:
            return {"statut": "traite",
                    "motif": "Retour noté, aucune absence ouverte"}
        return {"statut": "traite", "id_absence": ferme["id_absence"]}

    if len(allers) != 1:
        return {"statut": "illisible",
                "motif": f"{len(allers)} aller(s) reconnu(s) au lieu d'un seul"}

    id_aller = _enregistrer_segment(id_utilisateur, allers[0])
    id_retour = (_enregistrer_segment(id_utilisateur, retours[0], id_aller)
                 if retours else None)

    try:
        cree = un_seul("SELECT retenir_trajet(%(a)s, %(r)s) AS id_absence",
                       {"a": id_aller, "r": id_retour})
    except psycopg.Error as erreur:
        # La base a refusé : absence chevauchante, retour antérieur à l'aller.
        # C'est un refus métier, pas une panne — on le garde pour pouvoir le
        # regarder, et on continue avec les courriels suivants.
        diag = erreur.diag.message_primary if erreur.diag else str(erreur)
        return {"statut": "refuse", "motif": diag}

    assert cree is not None
    return {"statut": "traite", "id_absence": cree["id_absence"]}


def relever(id_utilisateur: int | None = None,
            messages: list[bytes] | None = None,
            annoncer: bool = False) -> dict:
    """Lit la boîte, déclare les absences trouvées, et rend compte de tout.

    Le compte rendu détaille chaque sort possible. Un relevé qui ne dirait que
    « trois absences créées » laisserait invisible le courriel qu'on n'a pas su
    lire, c'est-à-dire précisément celui qui demande une correction.

    `annoncer` sert à la relève automatique : elle dépose une notification,
    puisque personne ne regarde. Appelée depuis le bot, la réponse suffit et
    une notification ferait double emploi (R76).
    """
    if messages is None:
        # Les identifiants déjà traités partent avec la demande : le serveur
        # n'a alors à rendre que les corps des courriels neufs.
        connus = {ligne["identifiant"] for ligne in lister(
            "SELECT identifiant FROM courriel")}
        messages = lecteur.relever_imap(connus=connus)

    if id_utilisateur is None:
        proprietaire = un_seul(
            "SELECT id_utilisateur FROM utilisateur WHERE actif AND role = 'admin' "
            "ORDER BY id_utilisateur LIMIT 1")
        if proprietaire is None:
            raise ValueError("Aucun administrateur à qui rattacher les billets")
        id_utilisateur = proprietaire["id_utilisateur"]

    bilan = {"lus": len(messages), "traites": 0, "ignores": 0,
             "illisibles": 0, "refuses": 0, "deja_vus": 0, "absences": []}

    # Dans l'ordre du voyage, pas dans celui de la boîte. Un aller traité avant
    # le retour du voyage précédent se heurterait à une absence encore
    # ouverte, et serait refusé pour une raison qui n'existe pas.
    for lecture in sorted(map(lecteur.analyser, messages), key=_quand):

        if _deja_vu(lecture.identifiant):
            bilan["deja_vus"] += 1
            continue

        if lecture.statut != "traite":
            _consigner(lecture, lecture.statut, lecture.motif)
            bilan["ignores" if lecture.statut == "ignore" else "illisibles"] += 1
            continue

        resultat = _appliquer(lecture, id_utilisateur)
        _consigner(lecture, resultat["statut"], resultat.get("motif"),
                   id_utilisateur, resultat.get("id_absence"))

        if resultat["statut"] == "traite":
            bilan["traites"] += 1
            # Un billet de retour sans aller connu est traité sans rien créer :
            # il n'y avait pas d'absence à fermer.
            if resultat.get("id_absence") is not None:
                bilan["absences"].append(resultat["id_absence"])
        else:
            bilan["illisibles" if resultat["statut"] == "illisible"
                  else "refuses"] += 1

    if bilan["absences"]:
        # Le planning se refait une seule fois, à la fin : replacer entre
        # chaque courriel ferait le même travail plusieurs fois pour rien.
        from api.ordonnanceur import placer
        bilan["occurrences_replacees"] = placer()

    if annoncer and (bilan["traites"] or bilan["illisibles"] or bilan["refuses"]):
        # R76 : une absence déclarée sans qu'on l'ait demandée doit s'annoncer.
        # Geler deux jours de ménage en silence sur une analyse fausse est le
        # défaut qu'il faut éviter avant tous les autres.
        executer(
            "INSERT INTO notification (id_utilisateur, type, contenu) "
            "VALUES (%(u)s, 'alerte', %(texte)s) RETURNING id_notification",
            {"u": id_utilisateur, "texte": resume(bilan)},
        )

    return bilan


def a_revoir(limite: int = 10) -> list[dict]:
    """Courriels d'un expéditeur légitime qu'on n'a pas su exploiter."""
    return lister(
        "SELECT id_courriel, expediteur, sujet, recu_le, statut, motif "
        "  FROM v_courriel_a_revoir LIMIT %(n)s",
        {"n": limite},
    )


def oublier_les_rates() -> int:
    """Efface la trace des courriels non exploités, pour qu'ils soient relus.

    Corriger le lecteur ne sert à rien si les courriels sur lesquels il a
    échoué restent marqués comme vus. Les succès, eux, ne sont pas touchés :
    les relire recréerait des absences déjà déclarées.
    """
    lignes = lister(
        "DELETE FROM courriel WHERE statut IN ('illisible', 'refuse') "
        "RETURNING id_courriel")
    return len(lignes)


def absences_issues_de_billets() -> list[dict]:
    return lister(
        """
        SELECT c.id_courriel, c.reference, c.sujet,
               a.id_absence, lower(a.periode) AS debut, upper(a.periode) AS fin,
               a.lieu
          FROM courriel c
          JOIN absence a ON a.id_absence = c.id_absence
         WHERE c.statut = 'traite' AND upper(a.periode) > now()
         ORDER BY lower(a.periode)
        """
    )


def resume(bilan: dict) -> str:
    """Le compte rendu tel que le bot l'annonce."""
    if bilan["traites"] == 0 and bilan["illisibles"] == 0 and bilan["refuses"] == 0:
        return "Rien de neuf dans la boîte."

    lignes = []
    if bilan["traites"]:
        lignes.append(f"{bilan['traites']} billet(s) lu(s), absence déclarée.")
    if bilan["refuses"]:
        lignes.append(f"{bilan['refuses']} billet(s) refusé(s) — sans doute une "
                      f"absence déjà déclarée sur les mêmes dates.")
    if bilan["illisibles"]:
        # R75 : le dire, sinon le format change et plus rien n'arrive sans
        # qu'on sache pourquoi.
        lignes.append(f"{bilan['illisibles']} courriel(s) SNCF que je n'ai pas su "
                      f"lire. Le format a peut-être changé : « /billets » les liste.")
    return "\n".join(lignes)
