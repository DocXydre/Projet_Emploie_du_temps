"""Où l'on est, et les questions de HAL qui en découlent   (POS, SOI, H2 à H5)

L'iPhone envoie une position à chaque passage d'un cercle et à chaque ouverture
de l'appli (POS-2). La base la rattache à un lieu connu et garde le passage
(`recevoir_position`). Le reste se fait ici, dans le travailleur, toutes les
cinq minutes : c'est là que tournent les appels planifiés de HAL.

    arrivé dans un lieu de séjour       HAL du foyer : « tu y restes ? »  (POS-7)
    rentré au foyer, absence en cours   HAL du foyer : « je la ferme ? »  (POS-8)
    séance commencée, pas sur place     HAL sport : « tu y vas ? »        (POS-9)
    cours commencé, pas à l'école       HAL du foyer : « il a lieu ? »    (POS-10)
    soirée de la veille, au réveil      HAL sport : « comment ça s'est passé ? »
                                                                         (SOI-3)
    séance dehors dans l'heure          seuils, puis HAL sport           (MTO-3, MTO-4)

Chaque question est notée avant d'être posée, une fois pour toutes. Un appel
qui échoue retire sa note : le passage suivant réessaie, tant que la question
vaut encore. Aucune question pendant les heures de silence (POS-12), ni si la
position n'est pas sue (POS-6).
"""

import logging
from datetime import datetime, timedelta

from psycopg.types.json import Jsonb

from api.base import executer, lister, un_seul

LOG = logging.getLogger(__name__)

# POS-9, POS-10 : le délai avant de demander, et jusqu'à quand la question vaut.
APRES_LE_DEBUT = timedelta(minutes=15)
SEANCE_VAUT = timedelta(minutes=60)
COURS_VAUT = timedelta(minutes=45)
# POS-7, POS-8 : une arrivée de plus de six heures n'appelle plus de question.
ARRIVEE_VAUT = timedelta(hours=6)
# MTO-3 : une heure avant, à un passage près.
METEO_AVANT_MIN = timedelta(minutes=45)
METEO_AVANT_MAX = timedelta(minutes=65)
# SOI-3 : la nuit est finie depuis dix minutes.
APRES_LE_REVEIL = timedelta(minutes=10)


# ---------------------------------------------------------------------------
# Réception                                                   (opération H2)
# ---------------------------------------------------------------------------

def recevoir(id_utilisateur: int, latitude: float | None, longitude: float | None,
             precision_m: float | None, instant: datetime | None, autorisation: str,
             precise: bool, sortie_de: int | None = None) -> dict:
    """POS-2 à POS-4 : la base trouve le lieu et garde le passage. `sortie_de` :
    l'iPhone est sorti de ce lieu sans avoir eu le temps d'un relevé."""
    ligne = executer(
        "SELECT recevoir_position(%(u)s, %(la)s::NUMERIC, %(lo)s::NUMERIC, %(p)s::NUMERIC, "
        "%(i)s, %(a)s, %(pr)s, %(s)s::INTEGER) AS r",
        {"u": id_utilisateur, "la": latitude, "lo": longitude, "p": precision_m,
         "i": instant, "a": autorisation, "pr": precise, "s": sortie_de})
    rendu = dict(ligne["r"])
    lieu = un_seul("SELECT nom, nature FROM lieu_connu WHERE id_lieu_connu = %(l)s",
                   {"l": rendu.get("id_lieu_connu")}) if rendu.get("id_lieu_connu") else None
    rendu["lieu"] = lieu["nom"] if lieu else None
    rendu["nature"] = lieu["nature"] if lieu else None
    rendu["sue"] = bool(un_seul("SELECT position_sue(%(u)s) AS s",
                                {"u": id_utilisateur})["s"])
    return rendu


# ---------------------------------------------------------------------------
# Les questions
# ---------------------------------------------------------------------------

def _noter(id_utilisateur: int, nature: str, cle: str, detail: dict | None = None) -> bool:
    """Prend la question : faux si elle a déjà été posée."""
    return executer(
        """INSERT INTO question_presence (id_utilisateur, nature, cle, detail)
           VALUES (%(u)s, %(n)s, %(c)s, %(d)s)
           ON CONFLICT (id_utilisateur, nature, cle) DO NOTHING RETURNING id_question""",
        {"u": id_utilisateur, "n": nature, "c": cle,
         "d": Jsonb(detail) if detail else None}) is not None


def _oublier(id_utilisateur: int, nature: str, cle: str) -> None:
    executer("DELETE FROM question_presence WHERE id_utilisateur = %(u)s "
             "AND nature = %(n)s AND cle = %(c)s", {"u": id_utilisateur, "n": nature, "c": cle})


def demander(id_utilisateur: int, nature: str, cle: str, hal: str, moment: str,
             precision: str, id_occurrence: int | None = None,
             detail: dict | None = None) -> bool:
    """Pose une question par HAL, une seule fois. Vrai si HAL a répondu."""
    from api.coach import appel
    if not _noter(id_utilisateur, nature, cle, detail):
        return False
    demande = appel.Demande(id_utilisateur=id_utilisateur, moment=moment,
                            declencheur="systeme", precision=precision,
                            id_occurrence=id_occurrence, hal=hal)
    try:
        appel.appeler_coach(demande)
        return True
    except (appel.CoachInactif, appel.FoyerInactif):
        # Sans ce HAL, rien à demander : la note reste, pour ne pas réessayer.
        return False
    except appel.EchecAppel as echec:
        LOG.warning("Question %s (%s) sans réponse de HAL : %s", nature, cle, echec.motif)
        _oublier(id_utilisateur, nature, cle)
        return False


def _comptes_suivis() -> list[dict]:
    """POS-6, POS-12 : les comptes dont on sait où ils sont, hors silence."""
    return lister(
        """SELECT u.id_utilisateur, u.pseudo, u.coach_actif
             FROM utilisateur u
            WHERE u.actif AND position_sue(u.id_utilisateur)
              AND NOT COALESCE(en_silence(u.id_utilisateur), FALSE)""")


def arrivees(id_utilisateur: int) -> int:
    """POS-7, POS-8 : une arrivée dans un lieu de séjour, ou au foyer avec une absence."""
    poses = 0
    arrivee = un_seul(
        """SELECT pr.id_presence, lower(pr.periode) AS depuis, l.nom, l.nature,
                  l.id_lieu_connu,
                  (SELECT a.id_absence FROM absence a
                    WHERE a.id_utilisateur = pr.id_utilisateur AND a.periode @> now()
                    LIMIT 1) AS absence,
                  (SELECT upper(a.periode) FROM absence a
                    WHERE a.id_utilisateur = pr.id_utilisateur AND a.periode @> now()
                    LIMIT 1) AS absence_fin
             FROM presence pr JOIN lieu_connu l ON l.id_lieu_connu = pr.id_lieu_connu
            WHERE pr.id_utilisateur = %(u)s AND upper_inf(pr.periode)
              AND lower(pr.periode) > now() - %(v)s""",
        {"u": id_utilisateur, "v": ARRIVEE_VAUT})
    if arrivee is None:
        return 0
    from api.coach.clair import clair
    if arrivee["nature"] == "sejour" and arrivee["absence"] is None:
        precision = (
            f"Question de présence (POS-7). L'iPhone dit que l'utilisateur est arrivé à "
            f"{arrivee['nom']} (id_lieu_connu {arrivee['id_lieu_connu']}), un lieu où il dort, "
            f"le {clair(arrivee['depuis'])}, et il n'a pas d'absence en cours. Demande-lui "
            "en une phrase s'il y reste, et jusqu'à quand, avec deux ou trois réponses "
            "prêtes. Ne déclare rien maintenant : c'est sa réponse qui le fera, avec "
            "`declarer_absence` (debut : son arrivée, id_lieu_connu de ce lieu).")
        poses += demander(id_utilisateur, "sejour", str(arrivee["id_presence"]), "foyer",
                          "presence", precision)
    elif arrivee["nature"] == "foyer" and arrivee["absence"] is not None:
        precision = (
            f"Question de présence (POS-8). L'iPhone dit que l'utilisateur est rentré au "
            f"foyer le {clair(arrivee['depuis'])}, alors que son absence n° "
            f"{arrivee['absence']} court jusqu'au {clair(arrivee['absence_fin'])}. "
            "Demande-lui s'il est rentré pour de bon, avec des réponses prêtes. Ne ferme "
            "rien maintenant : sur sa réponse, `declarer_absence` avec retour à l'heure "
            "de son arrivée.")
        poses += demander(id_utilisateur, "retour", str(arrivee["id_presence"]), "foyer",
                          "presence", precision)
    return poses


def seances_manquees(id_utilisateur: int) -> int:
    """POS-9 : une séance commencée depuis quinze minutes, dans un lieu qui a une
    adresse, et l'on n'y est pas."""
    from api.coach.clair import clair
    poses = 0
    for s in lister(
            """SELECT o.id_occurrence, o.debut_seance, ls.libelle, lc.nom AS lieu,
                      lc.id_lieu_connu, pr.id_lieu_connu AS ici, ici.nom AS ici_nom
                 FROM occurrence o
                 JOIN lieu_sport ls ON ls.id_lieu = o.id_lieu
                 JOIN lieu_connu lc ON lc.id_lieu_connu = ls.id_lieu_connu
                 LEFT JOIN LATERAL presence_a(o.id_utilisateur) pr ON TRUE
                 LEFT JOIN lieu_connu ici ON ici.id_lieu_connu = pr.id_lieu_connu
                WHERE o.id_utilisateur = %(u)s AND o.statut IN ('planifiee', 'notifiee')
                  AND o.debut_seance BETWEEN now() - %(v)s AND now() - %(a)s
                  AND pr.id_presence IS NOT NULL
                  AND pr.id_lieu_connu IS DISTINCT FROM lc.id_lieu_connu
                  AND NOT EXISTS (SELECT 1 FROM serie_saisie x
                                   WHERE x.id_occurrence = o.id_occurrence)
                  AND NOT EXISTS (SELECT 1 FROM activite_sante a
                                   WHERE a.id_occurrence = o.id_occurrence)""",
            {"u": id_utilisateur, "v": SEANCE_VAUT, "a": APRES_LE_DEBUT}):
        ou = s["ici_nom"] or "ailleurs, dans aucun lieu connu"
        precision = (
            f"Question de présence (POS-9). La séance {s['id_occurrence']} ({s['libelle']}) "
            f"a commencé à {clair(s['debut_seance'])} à {s['lieu']}, et l'utilisateur n'y "
            f"est pas : il est {ou}. Demande-lui en une phrase s'il y va, avec deux ou trois "
            "réponses prêtes (plus tard, pas aujourd'hui). Ne change rien maintenant : sa "
            "réponse décalera l'heure ou déclarera la séance pas faite.")
        poses += demander(id_utilisateur, "seance", str(s["id_occurrence"]), "sport",
                          "absent", precision, id_occurrence=s["id_occurrence"])
    return poses


def cours_manques(id_utilisateur: int) -> int:
    """POS-10 : un cours commencé depuis quinze minutes, et l'on n'est pas à l'école.
    Une question par demi-journée."""
    from api.coach.clair import clair, fuseau
    c = un_seul(
        """SELECT o.id_occupation, o.libelle, lower(o.periode) AS debut, upper(o.periode) AS fin,
                  e.nom AS ecole, ici.nom AS ici_nom
             FROM occupation o
             JOIN lieu_connu e ON e.id_utilisateur = o.id_utilisateur AND e.nature = 'etudes'
             LEFT JOIN LATERAL presence_a(o.id_utilisateur) pr ON TRUE
             LEFT JOIN lieu_connu ici ON ici.id_lieu_connu = pr.id_lieu_connu
            WHERE o.id_utilisateur = %(u)s AND o.type = 'cours'
              AND lower(o.periode) BETWEEN now() - %(v)s AND now() - %(a)s
              AND pr.id_presence IS NOT NULL
              AND COALESCE(ici.nature, '') <> 'etudes'
              AND NOT EXISTS (SELECT 1 FROM absence a WHERE a.id_utilisateur = o.id_utilisateur
                                                       AND a.periode @> now())
            ORDER BY lower(o.periode) LIMIT 1""",
        {"u": id_utilisateur, "v": COURS_VAUT, "a": APRES_LE_DEBUT})
    if c is None:
        return 0
    debut = c["debut"].astimezone(fuseau())
    cle = f"{debut:%Y-%m-%d}-{'matin' if debut.hour < 13 else 'apres-midi'}"
    ou = c["ici_nom"] or "ailleurs, dans aucun lieu connu"
    precision = (
        f"Question de présence (POS-10). Le cours « {c['libelle']} » "
        f"(id_occupation {c['id_occupation']}) a commencé à {clair(c['debut'])}, jusqu'à "
        f"{clair(c['fin'])}, et l'utilisateur n'est pas à {c['ecole']} : il est {ou}. "
        "Demande-lui en une phrase si le cours a lieu, avec des réponses prêtes (annulé, "
        "j'y vais, je ne vais pas en cours). Annulé : `annuler_cours`, ce qui libère le "
        "créneau ; et les autres cours de la demi-journée s'il le dit. Ne fais rien "
        "avant sa réponse.")
    return int(demander(id_utilisateur, "cours", cle, "foyer", "presence", precision))


def soirees_du_reveil(id_utilisateur: int) -> int:
    """SOI-3 : la soirée de la veille, au réveil. Le réveil est la fin de la
    nuit vue par la montre, ou au plus tard l'heure du bilan du matin."""
    from api.coach.clair import clair
    s = un_seul(
        """SELECT so.id_soiree, so.nuit, so.origine,
                  (SELECT max(upper(sp.periode)) FROM sommeil_phase sp
                    WHERE sp.id_utilisateur = so.id_utilisateur
                      AND sp.phase <> 'au_lit'
                      AND upper(sp.periode) > debut_jour(so.nuit + 1)
                      AND upper(sp.periode) < debut_jour(so.nuit + 1) + INTERVAL '16 hours')
                    AS reveil,
                  ((so.nuit + 1) + u.heure_bilan) AT TIME ZONE 'Europe/Paris' AS bilan
             FROM soiree so JOIN utilisateur u ON u.id_utilisateur = so.id_utilisateur
            WHERE so.id_utilisateur = %(u)s AND so.statut = 'probable'
              AND so.nuit = jour_de(now()) - 1 AND u.coach_actif""",
        {"u": id_utilisateur})
    if s is None:
        return 0
    from datetime import UTC
    maintenant = datetime.now(UTC)
    reveille = s["reveil"] is not None and s["reveil"] + APRES_LE_REVEIL <= maintenant
    if not reveille and maintenant < s["bilan"]:
        return 0
    reveil = (f"La montre voit la fin de sa nuit à {clair(s['reveil'])}."
              if s["reveil"] else "La montre n'a pas encore envoyé sa nuit.")
    precision = (
        f"Question de soirée (SOI-3). Hier soir ({s['nuit']}), à minuit, l'utilisateur "
        "n'était ni au foyer ni dans un lieu où il dort : soirée probable. " + reveil
        + " Demande-lui simplement comment s'est passée sa soirée : ce qu'il a bu, à "
        "quelle heure il s'est couché, comment il se sent, avec des réponses prêtes (« pas "
        "une soirée », « tranquille », « grosse soirée »). Pas de morale (SOI-6). Sa réponse "
        f"se note avec `noter_soiree` (nuit {s['nuit']}). Regarde déjà la séance du jour : "
        "s'il faudra l'alléger, dis-le après sa réponse, pas avant.")
    return int(demander(id_utilisateur, "soiree", str(s["nuit"]), "sport", "soiree",
                        precision))


def controles_de_presence() -> dict:
    """Toutes les cinq minutes (opérations H3 et H4)."""
    bilan = {"questions": 0}
    for compte in _comptes_suivis():
        u = compte["id_utilisateur"]
        for controle in (arrivees, seances_manquees, cours_manques, soirees_du_reveil):
            try:
                bilan["questions"] += controle(u)
            except Exception:  # noqa: BLE001 - un contrôle ne prive pas les autres
                LOG.exception("Contrôle %s impossible pour %s", controle.__name__,
                              compte["pseudo"])
    return bilan


def reperer_les_soirees() -> int:
    """SOI-1 : minuit."""
    return (executer("SELECT reperer_les_soirees() AS n") or {}).get("n", 0)


# ---------------------------------------------------------------------------
# La météo d'une heure avant                                  (opération H5)
# ---------------------------------------------------------------------------

def controles_meteo() -> int:
    """MTO-3, MTO-4 : chaque séance dehors qui commence dans l'heure est contrôlée
    une fois ; un seuil franchi fait appeler HAL. Sans réponse d'Open-Meteo, rien
    n'est noté, et le passage suivant réessaie (MTO-10)."""
    from datetime import UTC

    from api import meteo
    from api.coach.clair import aujourd_hui, clair, fuseau
    maintenant = datetime.now(UTC)
    appels = 0
    for s in meteo.seances_dehors(None, maintenant + METEO_AVANT_MIN,
                                  maintenant + METEO_AVANT_MAX):
        u = s["id_utilisateur"]
        if un_seul("SELECT 1 AS ok FROM question_presence WHERE id_utilisateur = %(u)s "
                   "AND nature = 'meteo' AND cle = %(c)s",
                   {"u": u, "c": str(s["id_occurrence"])}):
            continue
        heures = meteo.pendant(s, meteo.FRAICHEUR_CONTROLE)
        if heures is None:
            continue
        franchis = meteo.seuils_franchis(heures)
        if not franchis:
            _noter(u, "meteo", str(s["id_occurrence"]), {"franchis": []})
            continue
        jour = s["debut"].astimezone(fuseau()).date() if s["debut"] else aujourd_hui()
        journee = meteo.journee(s["latitude"], s["longitude"], jour, maintenant) or []
        precision = (
            f"Contrôle météo d'une heure avant (MTO-4). La séance {s['id_occurrence']} "
            f"({s['type_seance'] or s['lieu']}, {s['etat'] or 'posée à la main'}) commence "
            f"à {clair(s['debut'])}, dehors, à {s['point']}. Seuils franchis : "
            f"{', '.join(franchis)}.\nPrévision du reste de la journée, heure par heure :\n"
            + "\n".join(f"- {x}" for x in journee)
            + "\nCherche mieux : un créneau plus tard le même jour où ça passe, le tapis de "
            "la salle (un autre lieu de la discipline), ou une autre séance. Propose-le : "
            "un ajustement sur une séance validée (nature deplacer, avec id_lieu pour le "
            "tapis), une nouvelle version sur une séance proposée. Rien ne change sans lui : "
            "dis en deux phrases ce que tu proposes et pourquoi. Si rien n'est mieux, "
            "dis-le simplement, avec ce qu'il faut prévoir (veste, gants, eau).")
        if meteo_demande(u, s, franchis, precision):
            appels += 1
    return appels


def meteo_demande(id_utilisateur: int, seance: dict, franchis: list[str],
                  precision: str) -> bool:
    return demander(id_utilisateur, "meteo", str(seance["id_occurrence"]), "sport", "meteo",
                    precision, id_occurrence=seance["id_occurrence"],
                    detail={"franchis": franchis})
