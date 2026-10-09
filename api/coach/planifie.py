"""Ce qui tourne tout seul : la synthèse du soir, la révision, les essais
                                              (opération C9 : COA-9, COA-11)

    23h00               clôture du jour, puis synthèse. Révision le dimanche.
    23h05, 23h20, 23h50 nouveaux essais si l'appel a échoué. Chacun reprend là
                        où le précédent s'est arrêté.
    6h55                rattrapage, si les trois essais ont échoué.
    0h05                fenêtres de mesure expirées, pauses arrivées à leur terme.

Les heures sont celles de Paris : l'ordonnanceur passe le fuseau à chaque
déclencheur.
"""

import logging
from datetime import timedelta

from api.base import executer, lister, un_seul
from api.coach import appel
from api.coach.clair import aujourd_hui, maintenant

LOG = logging.getLogger(__name__)

# COA-11 : les nouveaux essais, en minutes après 23 h.
ESSAIS_APRES_MINUTES = (5, 20, 50)


def comptes_avec_coach() -> list[dict]:
    return lister(
        """SELECT u.id_utilisateur, u.pseudo,
                  (SELECT jour_de(now()) - lower(pa.periode) FROM pause pa
                    WHERE pa.id_utilisateur = u.id_utilisateur
                      AND pa.periode @> jour_de(now())) AS jours_de_pause
             FROM utilisateur u WHERE u.actif AND u.coach_actif
            ORDER BY u.id_utilisateur""")


def clore_le_jour(id_utilisateur: int) -> dict:
    """PLN-9 : faite ou pas faite, sans le modèle. Tous les soirs (PAU-5)."""
    executer("SELECT solder_ajustements()")
    ligne = executer("SELECT clore_seances_du_jour(%(u)s) AS bilan", {"u": id_utilisateur})
    return (ligne or {}).get("bilan") or {}


def figer(id_utilisateur: int) -> None:
    """SAI-8 : les séries du jour se figent à la fin de la synthèse."""
    executer("SELECT figer_series(%(u)s)", {"u": id_utilisateur})


def synthese_due(compte: dict) -> bool:
    """PAU-3 : en pause, un soir sur trois, compté depuis le premier jour."""
    jours = compte.get("jours_de_pause")
    return jours is None or jours % 3 == 0


def _moment_du_soir(compte: dict) -> str:
    """Le dimanche, la synthèse fait aussi la révision. En pause, elle est suspendue."""
    dimanche = aujourd_hui().weekday() == 6
    return "revision" if dimanche and compte.get("jours_de_pause") is None else "synthese"


def _precision(cloture: dict) -> str:
    morceaux = []
    if cloture.get("faites"):
        morceaux.append(f"Séances comptées comme faites à la clôture de ce soir : "
                        f"{cloture['faites']}.")
    if cloture.get("pas_faites"):
        morceaux.append(f"Séances closes comme pas faites ce soir (id_occurrence) : "
                        f"{cloture['pas_faites']}. Décide de leur sort (PLN-10).")
    return " ".join(morceaux)


def synthese(id_utilisateur: int, moment: str = "synthese", cloture: dict | None = None,
             operation_id: str | None = None, essai: int = 1,
             declencheur: str = "ordonnanceur") -> dict:
    """Un appel de synthèse ou de révision. Lève EchecAppel s'il échoue."""
    demande = appel.Demande(
        id_utilisateur=id_utilisateur, moment=moment, declencheur=declencheur,
        precision=_precision(cloture or {}) or None,
        operation_id=operation_id, essai=essai)
    rendu = appel.appeler_coach(demande)
    figer(id_utilisateur)
    return rendu


def soir(programmer_essai=None) -> dict:
    """23 h : pour chaque compte qui a le coach.

    `programmer_essai(minutes, compte, moment, operation_id, essai)` est donné
    par l'ordonnanceur : c'est lui qui sait poser un rendez-vous.
    """
    bilan = {}
    for compte in comptes_avec_coach():
        u = compte["id_utilisateur"]
        try:
            cloture = clore_le_jour(u)
            if not synthese_due(compte):
                # PAU-5 : un soir sans synthèse clôt et fige quand même.
                figer(u)
                bilan[compte["pseudo"]] = "pause : pas de synthèse ce soir"
                continue
            moment = _moment_du_soir(compte)
            synthese(u, moment, cloture)
            bilan[compte["pseudo"]] = moment
        except appel.EchecAppel as echec:
            bilan[compte["pseudo"]] = f"échec : {echec.motif}"
            if programmer_essai is not None:
                programmer_essai(ESSAIS_APRES_MINUTES[0], u, moment, echec.operation_id, 2)
        except Exception:  # noqa: BLE001 - un compte ne doit pas priver l'autre
            LOG.exception("Soir du coach impossible pour %s", compte["pseudo"])
            bilan[compte["pseudo"]] = "erreur"
    return bilan


def nouvel_essai(id_utilisateur: int, moment: str, operation_id: str, essai: int,
                 programmer_essai=None) -> bool:
    """COA-11, COA-24 : l'essai garde le numéro d'opération et termine le travail."""
    try:
        synthese(id_utilisateur, moment, None, operation_id, essai)
        return True
    except appel.EchecAppel as echec:
        rang = essai - 1                       # essai 2 -> index 1 des délais
        if programmer_essai is not None and rang < len(ESSAIS_APRES_MINUTES):
            attente = ESSAIS_APRES_MINUTES[rang] - ESSAIS_APRES_MINUTES[rang - 1]
            programmer_essai(attente, id_utilisateur, moment, echec.operation_id, essai + 1)
        else:
            # Après le dernier échec, un message le dit. Rattrapage à 6h55.
            figer(id_utilisateur)
            executer(
                """INSERT INTO notification (id_utilisateur, type, contenu)
                   VALUES (%(u)s, 'coach', %(c)s)""",
                {"u": id_utilisateur,
                 "c": "La synthèse de ce soir n'a pas pu se faire : le coach est resté "
                      "injoignable. Je réessaie demain matin, avant ton bilan."})
        return False


def rattrapage() -> dict:
    """6h55 : la synthèse de la veille, si tous les essais ont échoué."""
    bilan = {}
    hier_23h = (maintenant() - timedelta(days=1)).replace(hour=22, minute=30, second=0)
    for compte in comptes_avec_coach():
        u = compte["id_utilisateur"]
        dernier = un_seul(
            """SELECT a.statut, a.operation, a.moment, a.essai
                 FROM appel_coach a
                WHERE a.id_utilisateur = %(u)s AND a.declencheur = 'ordonnanceur'
                  AND a.moment IN ('synthese', 'revision') AND a.debut >= %(d)s
                ORDER BY a.id_appel DESC LIMIT 1""", {"u": u, "d": hier_23h})
        if dernier is None or dernier["statut"] != "echoue":
            continue
        try:
            synthese(u, dernier["moment"], None, dernier["operation"], dernier["essai"] + 1)
            bilan[compte["pseudo"]] = "rattrapée"
        except appel.EchecAppel as echec:
            bilan[compte["pseudo"]] = f"échec : {echec.motif}"
    return bilan


def reprise(id_utilisateur: int, motif: str | None = None,
            declencheur: str = "systeme") -> dict | None:
    """PAU-6 : à la fin d'une pause, le coach relit la période et propose la reprise."""
    precision = ("La pause vient de se terminer"
                 + (f" (motif : {motif})" if motif else "")
                 + ". Relis ce qui s'est passé pendant la pause, détaille une semaine de "
                   "reprise et propose-la. Si le plan est arrivé à son terme ou n'a plus de "
                   "sens, construis-en un autre.")
    demande = appel.Demande(id_utilisateur=id_utilisateur, moment="revision",
                            declencheur=declencheur, precision=precision,
                            extra={"reprise": True})
    try:
        return appel.appeler_coach(demande)
    except (appel.EchecAppel, appel.CoachInactif) as echec:
        LOG.warning("Reprise après pause impossible : %s", echec)
        return None


def minuit() -> dict:
    """0h05 : fenêtres de mesure expirées, pauses arrivées à leur terme (MES-3, PAU-6)."""
    expirees = (executer("SELECT expirer_fenetres() AS n") or {}).get("n", 0)
    finies = lister(
        """SELECT pa.id_utilisateur, pa.motif FROM pause pa
             JOIN utilisateur u ON u.id_utilisateur = pa.id_utilisateur
            WHERE upper(pa.periode) = jour_de(now()) AND u.coach_actif AND u.actif""")
    for pause in finies:
        reprise(pause["id_utilisateur"], pause["motif"])
    return {"fenetres_expirees": expirees, "pauses_levees": len(finies)}


def matin() -> int:
    """NOT-12 : le bilan du matin dit quand une semaine attend d'être validée."""
    return (executer("SELECT rappeler_semaine_a_valider() AS n") or {}).get("n", 0)
