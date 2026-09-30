"""De la confirmation d'achat à l'absence déclarée.

Un billet lu est enregistré comme n'importe quel trajet, puis retenu par la
même fonction que celle du bot : un second chemin d'écriture finirait par
diverger du premier.

Ce module ne parle ni à IMAP ni à la SNCF. Il reçoit des courriels bruts, ce
qui permet de rejouer une boîte entière dans les tests.
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
    """Garde trace, y compris des courriels dont on n'a rien su faire (BIL-8)."""
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


def _resume(lecture: Lecture) -> str:
    """Ce qui s'affichera dans le détail du train au planning.

    Le numéro de train et la référence sont les deux choses qu'on cherche quand
    on est sur le quai. Autant les y mettre.
    """
    morceaux = ["Billet acheté"]
    if lecture.train:
        morceaux.append(lecture.train)
    if lecture.reference:
        morceaux.append(lecture.reference)
    return " · ".join(morceaux)[:200]


def _enregistrer_segment(id_utilisateur: int, segment: Segment,
                         id_trajet_aller: int | None = None,
                         resume: str = "Billet acheté") -> int:
    ligne = executer(
        """
        INSERT INTO trajet (id_utilisateur, sens, periode, origine, destination,
                            resume, id_trajet_aller)
        VALUES (%(u)s, %(sens)s, tstzrange(%(d)s, %(a)s, '[)'),
                %(o)s, %(dest)s, %(resume)s, %(aller)s)
        RETURNING id_trajet
        """,
        {
            "u": id_utilisateur, "sens": segment.sens,
            "d": segment.depart, "a": segment.arrivee,
            "o": NOMS.get(segment.depart_gare, segment.depart_gare),
            "dest": NOMS.get(segment.arrivee_gare, segment.arrivee_gare),
            "resume": resume, "aller": id_trajet_aller,
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
    """Billet dont on connaît le jour, pas l'heure.                     (BIL-6)

    Aucun appariement entre courriels n'est nécessaire : un billet vers la gare
    famille ouvre l'absence, un billet qui en revient la ferme.

    Les bornes sont prises à l'intérieur du voyage — lendemain du départ, matin
    du retour — car ce sont les seules journées certaines.
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

    Un billet contient un aller seul, ou un aller et un retour. Deux allers
    correspondent à deux voyages distincts et ne sont pas traités ici.
    """
    if max(s.arrivee for s in lecture.segments) < datetime.now(UTC):
        # BIL-17 : un voyage terminé ne gèle rien et ne s'annonce pas. La relève
        # regarde un mois en arrière ; rejouer ces billets créerait des absences
        # dans le passé et annoncerait des trajets dont on est déjà revenu.
        return {"statut": "traite", "motif": "Voyage déjà passé", "passe": True}

    if len(lecture.segments) == 1 and lecture.segments[0].sans_horaire:
        return _appliquer_sans_horaire(lecture.segments[0], id_utilisateur)

    allers = [s for s in lecture.segments if s.sens == "aller"]
    retours = [s for s in lecture.segments if s.sens == "retour"]

    if len(retours) > 1:
        return {"statut": "illisible",
                "motif": f"{len(retours)} retours reconnus dans le même billet"}

    if not allers and len(retours) == 1:
        # Un retour acheté à part : le cas ordinaire depuis que la SNCF envoie
        # un courriel par trajet. Le train s'affiche, et l'absence ouverte par
        # l'aller est raccordée sur l'heure du retour (BIL-15).
        id_retour = _enregistrer_segment(id_utilisateur, retours[0],
                                         resume=_resume(lecture))
        try:
            raccorde = un_seul("SELECT raccorder_retour(%(r)s) AS id_absence",
                               {"r": id_retour})
        except psycopg.Error as erreur:
            diag = erreur.diag.message_primary if erreur.diag else str(erreur)
            return {"statut": "refuse", "motif": diag}

        if raccorde is None or raccorde["id_absence"] is None:
            # Soit l'aller n'a jamais été vu, soit le retour tombe le jour du
            # départ et l'absence devient inutile. Dans les deux cas il y a de
            # quoi replacer : un train de plus au planning, une absence de moins.
            return {"statut": "traite", "replacer": True,
                    "motif": "Retour noté, aucune absence à raccorder"}
        return {"statut": "traite", "id_absence": raccorde["id_absence"]}

    if len(allers) != 1:
        return {"statut": "illisible",
                "motif": f"{len(allers)} aller(s) reconnu(s) au lieu d'un seul"}

    id_aller = _enregistrer_segment(id_utilisateur, allers[0],
                                    resume=_resume(lecture))
    id_retour = (_enregistrer_segment(id_utilisateur, retours[0], id_aller,
                                      resume=_resume(lecture))
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

    Le compte rendu détaille chaque sort possible : un relevé qui ne dirait que
    « trois absences créées » masquerait le courriel qu'on n'a pas su lire.

    `annoncer` sert à la relève automatique, qui dépose une notification
    puisque personne ne regarde (BIL-9).
    """
    if messages is None:
        # Les identifiants déjà traités partent avec la demande : le serveur
        # n'a alors à rendre que les corps des courriels neufs (BIL-1).
        from api.config import configuration

        connus = {ligne["identifiant"] for ligne in lister(
            "SELECT identifiant FROM courriel")}
        boites = configuration().boites

        # BIL-10 : une boîte par personne. Au-delà d'une, chacune est relevée
        # pour son propriétaire, sans quoi un billet gèlerait le planning de
        # quelqu'un qui n'est pas parti.
        if len(boites) > 1:
            total = _additionner([_relever_une_boite(b, id_utilisateur) for b in boites])
            if annoncer and _a_dire(total):
                _annoncer(total, id_utilisateur)
            return total

        if boites:
            messages = lecteur.relever_imap(connus=connus, boite_lue=boites[0])
            id_utilisateur = id_utilisateur or _compte_du_pseudo(boites[0].get("pseudo"))
        else:
            messages = lecteur.relever_imap(connus=connus)

    if id_utilisateur is None:
        id_utilisateur = _proprietaire()

    bilan = {"lus": len(messages), "traites": 0, "passes": 0, "ignores": 0,
             "illisibles": 0, "refuses": 0, "deja_vus": 0, "absences": [],
             "voyages": []}
    # Un billet peut changer le planning sans créer d'absence : un train de plus
    # à afficher, ou une absence rendue inutile par le retour du même jour.
    a_replacer = False

    # On trie par date de voyage et non par ordre d'arrivée dans la boîte,
    # pour que le retour d'un voyage soit traité avant l'aller du suivant.
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
            bilan["passes"] += bool(resultat.get("passe"))
            a_replacer = a_replacer or bool(resultat.get("replacer"))
            # Un billet de retour sans aller connu est traité sans rien créer :
            # il n'y avait pas d'absence à fermer.
            if resultat.get("id_absence") is not None:
                bilan["absences"].append(resultat["id_absence"])
            # BIL-11 : tout voyage se dit, même sans absence, et même quand il
            # ne va pas chez la famille. Sauf s'il est passé (BIL-17) : là, il
            # n'y a plus rien à en dire.
            voyage = (None if resultat.get("passe") else
                      _raconter(lecture, id_utilisateur,
                                resultat.get("id_absence") is not None))
            if voyage:
                bilan["voyages"].append(voyage)
        else:
            bilan["illisibles" if resultat["statut"] == "illisible"
                  else "refuses"] += 1

    if bilan["absences"] or a_replacer:
        # Un seul replacement, à la fin, pour tout ce que la relève a changé.
        from api.ordonnanceur import placer
        bilan["occurrences_replacees"] = placer()

    if annoncer and _a_dire(bilan):
        _annoncer(bilan, id_utilisateur)

    return bilan


def _a_dire(bilan: dict) -> bool:
    """Y a-t-il quelque chose à annoncer ?

    Un billet dont le voyage est passé est lu, classé, et tu : la relève
    regarde un mois en arrière, et ce n'est pas une nouvelle (BIL-17).
    """
    return bool(bilan["traites"] - bilan.get("passes", 0)
                or bilan["illisibles"] or bilan["refuses"])


def _proprietaire() -> int:
    ligne = un_seul(
        "SELECT id_utilisateur FROM utilisateur WHERE actif AND role = 'admin' "
        "ORDER BY id_utilisateur LIMIT 1")
    if ligne is None:
        raise ValueError("Aucun administrateur à qui rattacher les billets")
    return ligne["id_utilisateur"]


def _compte_du_pseudo(pseudo: str | None) -> int:
    """Le compte d'une boîte : son pseudo, sinon l'administrateur."""
    if pseudo:
        ligne = un_seul(
            "SELECT id_utilisateur FROM utilisateur WHERE pseudo = %(p)s AND actif",
            {"p": pseudo})
        if ligne is not None:
            return ligne["id_utilisateur"]
        LOG.warning("Boîte rattachée à « %s », compte inconnu : "
                    "les billets iront à l'administrateur", pseudo)
    return _proprietaire()


def _relever_une_boite(reglage: dict, id_utilisateur: int | None) -> dict:
    """Relève une boîte, pour la personne à qui elle appartient (BIL-10)."""
    connus = {ligne["identifiant"] for ligne in lister(
        "SELECT identifiant FROM courriel")}
    messages = lecteur.relever_imap(connus=connus, boite_lue=reglage)
    qui = id_utilisateur or _compte_du_pseudo(reglage.get("pseudo"))
    return relever(id_utilisateur=qui, messages=messages)


def _additionner(bilans: list[dict]) -> dict:
    total = {"lus": 0, "traites": 0, "passes": 0, "ignores": 0, "illisibles": 0,
             "refuses": 0, "deja_vus": 0, "absences": [], "voyages": []}
    for bilan in bilans:
        for cle in ("lus", "traites", "passes", "ignores", "illisibles",
                    "refuses", "deja_vus"):
            total[cle] += bilan.get(cle, 0)
        total["absences"] += bilan.get("absences", [])
        total["voyages"] += bilan.get("voyages", [])
        if bilan.get("occurrences_replacees"):
            total["occurrences_replacees"] = (total.get("occurrences_replacees", 0)
                                              + bilan["occurrences_replacees"])
    return total


def _annoncer(bilan: dict, id_utilisateur: int | None) -> None:
    # BIL-9 : une absence déclarée sans qu'on l'ait demandée doit s'annoncer.
    # Geler deux jours de ménage en silence sur une analyse fausse est le
    # défaut qu'il faut éviter avant tous les autres.
    for qui in {v["id_utilisateur"] for v in bilan.get("voyages", [])} or \
               {id_utilisateur or _proprietaire()}:
        sien = dict(bilan)
        sien["voyages"] = [v for v in bilan.get("voyages", [])
                           if v["id_utilisateur"] == qui]
        executer(
            "INSERT INTO notification (id_utilisateur, type, contenu) "
            "VALUES (%(u)s, 'alerte', %(texte)s) RETURNING id_notification",
            {"u": qui, "texte": resume(sien)},
        )


def _raconter(lecture: Lecture, id_utilisateur: int, absence: bool) -> dict | None:
    """Ce qu'il y a à dire d'un billet : où, quand, et si on note l'absence.

    On annonce des heures de départ, jamais d'arrivée : c'est ce que le billet
    dit, et les confirmations actuelles ne donnent pas l'arrivée (BIL-12).
    Annoncer une heure estimée comme un horaire serait mentir sur un détail
    qu'on vérifie en gare.
    """
    if not lecture.segments:
        return None

    aller = next((s for s in lecture.segments if s.sens == "aller"), None)
    retour = next((s for s in lecture.segments if s.sens == "retour"), None)
    depart = aller or retour
    return {
        "id_utilisateur": id_utilisateur,
        "destination": NOMS.get(depart.arrivee_gare, depart.arrivee_gare),
        "origine": NOMS.get(depart.depart_gare, depart.depart_gare),
        "depart": depart.depart,
        "retour": retour.depart if retour else None,
        "sens": depart.sens,
        "absence": absence,
    }


def a_revoir(limite: int = 10) -> list[dict]:
    """Courriels d'un expéditeur légitime qu'on n'a pas su exploiter."""
    return lister(
        "SELECT id_courriel, expediteur, sujet, recu_le, statut, motif "
        "  FROM v_courriel_a_revoir LIMIT %(n)s",
        {"n": limite},
    )


def relire_les_billets(jours: int = 120) -> dict:
    """Efface la mémoire des courriels récents pour que la relève les relise.

    Corriger le lecteur ne sert à rien tant que les courriels sur lesquels il
    s'est trompé restent marqués comme vus, et `oublier_les_rates` ne rouvre
    que ceux qu'il avait su signaler. Un courriel mal lu mais classé « traité »,
    lui, ne revient jamais : c'est exactement le retour dont l'absence n'avait
    rien à fermer.

    Les absences encore à venir nées d'un billet s'en vont avec leurs trains,
    puisqu'elles vont être recréées. Le passé n'est pas touché : il a été vécu
    tel quel, et un billet passé ne redéclare rien (BIL-17).
    """
    a_rendre = lister(
        """
        SELECT DISTINCT c.id_absence
          FROM courriel c
          JOIN absence a ON a.id_absence = c.id_absence
         WHERE upper(a.periode) > now()
        """)
    for ligne in a_rendre:
        executer("SELECT oublier_trajet(%(a)s) AS trains", {"a": ligne["id_absence"]})

    oublies = lister(
        "DELETE FROM courriel "
        " WHERE recu_le IS NULL OR recu_le > now() - make_interval(days => %(j)s) "
        "RETURNING id_courriel",
        {"j": jours})

    return {"absences_rendues": len(a_rendre), "courriels_oublies": len(oublies)}


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
    """Un voyage par absence, et non par courriel.

    Depuis que l'aller et le retour arrivent dans deux courriels, deux billets
    pointent sur la même absence. La lister deux fois donnerait deux lignes
    identiques et deux boutons pour annuler la même chose.
    """
    return lister(
        """
        SELECT min(c.id_courriel)                                AS id_courriel,
               string_agg(DISTINCT c.reference, ', '
                          ORDER BY c.reference)                  AS references,
               min(c.sujet)                                      AS sujet,
               a.id_absence, lower(a.periode) AS debut, upper(a.periode) AS fin,
               a.lieu,
               -- Sans billet de retour, la fin n'est qu'une supposition : la
               -- prochaine obligation connue (TRJ-7). Autant le dire.
               EXISTS (SELECT 1 FROM trajet t
                        WHERE t.id_absence = a.id_absence
                          AND t.sens = 'retour') AS retour_connu
          FROM courriel c
          JOIN absence a ON a.id_absence = c.id_absence
         WHERE c.statut = 'traite' AND upper(a.periode) > now()
         GROUP BY a.id_absence, a.periode, a.lieu
         ORDER BY lower(a.periode)
        """
    )


def _jour_heure(instant) -> str:
    from zoneinfo import ZoneInfo

    from api.config import configuration
    local = instant.astimezone(ZoneInfo(configuration().fuseau))
    return f"{local:%d/%m à %Hh%M}"


def _ce_qu_on_a_vu(bilan: dict) -> str:
    """Ce que la relève a trouvé, même quand elle n'a rien à déclarer.

    « Rien de neuf » tout court ne distingue pas une boîte vide d'une boîte
    qu'on ne sait plus lire, ni de billets qu'on avait déjà. C'est ce silence
    qui a laissé passer une lecture fausse pendant des mois.
    """
    comptes = [(bilan.get("deja_vus"), "déjà vu", "déjà vus"),
               (bilan.get("passes"), "voyage passé", "voyages passés"),
               (bilan.get("ignores"), "sans billet", "sans billet")]
    morceaux = [f"{n} {seul if n == 1 else plusieurs}"
                for n, seul, plusieurs in comptes if n]
    if not bilan.get("lus") and not morceaux:
        return ""
    return (f" {bilan.get('lus', 0)} courriel(s) relevé(s)"
            + (f" : {', '.join(morceaux)}" if morceaux else "") + ".")


def resume(bilan: dict) -> str:
    """Le compte rendu tel que le bot l'annonce."""
    if not _a_dire(bilan):
        return f"Rien de neuf dans la boîte.{_ce_qu_on_a_vu(bilan)}"

    lignes = []
    # BIL-11 : chaque voyage est nommé, où qu'il aille. Un billet pour Paris
    # compte autant qu'un billet pour Saint-Dié, et une journée aller-retour
    # se dit même si elle ne déclare pas d'absence.
    for voyage in bilan.get("voyages", []):
        if not voyage.get("depart"):
            continue
        if voyage["sens"] == "retour":
            # Un retour acheté à part : c'est un voyage du sens inverse, et le
            # dire « départ pour Nancy » n'aiderait personne.
            ligne = (f"🚆 Retour de {voyage.get('origine', '')}, "
                     f"départ le {_jour_heure(voyage['depart'])}")
            ligne += (". Absence ajustée." if voyage["absence"]
                      else ". Aucune absence à ajuster.")
            lignes.append(ligne)
            continue

        ligne = f"🚆 {voyage['destination']}, départ le {_jour_heure(voyage['depart'])}"
        if voyage["retour"]:
            ligne += f", retour le {_jour_heure(voyage['retour'])}"
        ligne += (". Absence notée." if voyage["absence"]
                  else ". Aller-retour dans la journée : rien n'est gelé.")
        lignes.append(ligne)

    neufs = bilan["traites"] - bilan.get("passes", 0)
    if neufs and not bilan.get("voyages"):
        lignes.append(f"{neufs} billet(s) lu(s).")
    if bilan["refuses"]:
        lignes.append(f"{bilan['refuses']} billet(s) refusé(s) — sans doute une "
                      f"absence déjà déclarée sur les mêmes dates.")
    if bilan["illisibles"]:
        # BIL-8 : le dire, sinon le format change et plus rien n'arrive sans
        # qu'on sache pourquoi.
        lignes.append(f"{bilan['illisibles']} courriel(s) SNCF que je n'ai pas su "
                      f"lire. Le format a peut-être changé : « /billets » les liste.")
    return "\n".join(lignes)
