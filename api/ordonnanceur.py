"""Déclenchement périodique : collectes, placement, notifications.

    toutes les heures   collecter les sources dont la fréquence est écoulée
    toutes les 2 h      relever les confirmations SNCF
    toutes les 6 h      calendriers personnels
    07h00               bilan du matin, puis placement
    07h10               propositions de week-end
    21h00               relance sur les tâches du jour non faites
    00h02               consommation de l'uniforme
    00h05               report d'office de ce qui n'a pas été fait

Les heures ci-dessus sont des heures de Paris. Le conteneur, lui, vit en UTC :
tous les horodatages en base sont ainsi comparables, quelle que soit la saison.
C'est seulement à l'affichage et au déclenchement qu'on repasse à l'heure d'ici.

Chaque tâche appelle la même fonction que l'endpoint correspondant : le chemin
de nuit reste ainsi couvert par les tests de l'API.
"""

import logging
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger

from api.base import executer
from api.collecteurs.service import CollecteImpossible, collecter_source, sources_a_collecter
from api.config import configuration

LOG = logging.getLogger(__name__)

_ordonnanceur: BackgroundScheduler | None = None


def collecter_les_sources_dues() -> dict:
    """Collecte ce qui est périmé, puis replace si quelque chose a bougé."""
    bilans = {}
    a_change = False

    for code in sources_a_collecter():
        try:
            bilan = collecter_source(code)
            bilans[code] = bilan
            a_change = a_change or bool(bilan["crees"] or bilan["mis_a_jour"] or bilan["annules"])
            LOG.info("Collecte %s : %s", code, bilan)
        except CollecteImpossible as erreur:
            LOG.warning("Collecte %s impossible : %s", code, erreur.message)
        except Exception:
            # Une source qui casse ne doit pas empêcher les autres de tourner,
            # ni tuer l'ordonnanceur.
            LOG.exception("Échec de la collecte %s", code)

    if a_change:
        placer()

    return bilans


def relever_la_boite() -> dict:
    """Lit les confirmations d'achat, et déclare les absences qui en découlent.

    Une boîte non configurée est un cas normal, pas une panne : la relève ne
    fait rien et l'on n'en parle qu'une fois, en journal.
    """
    from api import billets
    from api.collecteurs.courriel import BoiteIndisponible

    try:
        bilan = billets.relever(annoncer=True)
    except BoiteIndisponible as erreur:
        LOG.info("Relève de la boîte impossible : %s", erreur.message)
        return {}
    except Exception:
        # Le relevé tourne sans surveillance : il ne doit pas emporter
        # l'ordonnanceur avec lui.
        LOG.exception("Échec de la relève de la boîte")
        return {}

    if bilan.get("traites") or bilan.get("illisibles"):
        LOG.info("Relève : %s", bilan)
    return bilan


def proposer_les_weekends() -> dict:
    """Repère les week-ends libres, les annonce, et relance une fois.

    Appelé une fois par jour : un creux de deux jours n'apparaît pas d'une
    heure sur l'autre.
    """
    from api import propositions

    try:
        return propositions.tour_de_ronde()
    except Exception:
        LOG.exception("Échec des propositions de week-end")
        return {}


def placer() -> int:
    conf = configuration()
    resultat = executer("SELECT placer_taches(%(h)s, %(s)s) AS placees",
                        {"h": conf.horizon_jours, "s": conf.stabilite_jours})
    placees = (resultat or {}).get("placees", 0)
    LOG.info("Placement : %s occurrence(s)", placees)
    return placees


def bilan_du_matin() -> int:
    placer()
    resultat = executer("SELECT bilan_du_matin() AS creees")
    creees = (resultat or {}).get("creees", 0)
    LOG.info("Bilan du matin : %s notification(s)", creees)
    return creees


def relance_du_soir() -> int:
    resultat = executer("SELECT relance_du_soir() AS creees")
    creees = (resultat or {}).get("creees", 0)
    LOG.info("Relance du soir : %s rappel(s)", creees)
    return creees


def report_de_minuit() -> int:
    resultat = executer("SELECT reporter_taches_du_jour() AS reportees")
    reportees = (resultat or {}).get("reportees", 0)
    LOG.info("Report d'office : %s tâche(s)", reportees)
    return reportees


def consommer_l_uniforme() -> int:
    """Compte les journées de travail passées, et salit ce qui doit l'être.

    Traite tous les jours non encore comptés, et pas seulement la veille : la
    machine peut avoir été éteinte plusieurs jours.
    """
    resultat = executer("SELECT rattraper_uniforme() AS sales")
    sales = (resultat or {}).get("sales", 0)
    if sales:
        LOG.info("Uniforme : %s article(s) au sale", sales)
        # Le stock a changé : la date limite de lessive aussi.
        placer()
    return sales


def demarrer() -> BackgroundScheduler:
    global _ordonnanceur
    if _ordonnanceur is not None:
        return _ordonnanceur

    conf = configuration()
    ordonnanceur = BackgroundScheduler(timezone=conf.fuseau)

    def a(heure: int, minute: int) -> CronTrigger:
        """Un rendez-vous quotidien, à l'heure de Paris.

        Le fuseau est redonné ici. Un CronTrigger construit à la main fige le
        sien à la construction, en lisant celui du système — UTC dans le
        conteneur — et le fuseau du scheduler ne s'applique pas aux
        déclencheurs qu'on lui passe tout faits.
        """
        return CronTrigger(hour=heure, minute=minute, timezone=conf.fuseau)

    # Une première collecte tout de suite, sans attendre l'heure pleine. Le
    # serveur redémarre après une coupure ou un déploiement, et les emplois du
    # temps ont pu changer entre-temps : attendre une heure pour s'en rendre
    # compte n'aurait pas de sens.
    ordonnanceur.add_job(collecter_les_sources_dues, IntervalTrigger(hours=1),
                         id="collectes", name="Collecte des sources dues",
                         max_instances=1, coalesce=True,
                         next_run_time=datetime.now(ZoneInfo(conf.fuseau))
                         + timedelta(seconds=30))

    # Toutes les deux heures : suffisant pour un achat de billet, et ça évite
    # d'ouvrir des connexions IMAP en continu.
    ordonnanceur.add_job(relever_la_boite, IntervalTrigger(hours=2),
                         id="boite", name="Relève des confirmations SNCF",
                         max_instances=1, coalesce=True)

    ordonnanceur.add_job(bilan_du_matin, a(7, 0),
                         id="bilan", name="Bilan du matin", coalesce=True)

    # Après le bilan du matin : on lit ses messages une fois, et la
    # proposition arrive dans la même fournée que le reste.
    ordonnanceur.add_job(proposer_les_weekends, a(7, 10),
                         id="weekends", name="Propositions de week-end",
                         coalesce=True)

    ordonnanceur.add_job(relance_du_soir, a(21, 0),
                         id="relance", name="Relance du soir", coalesce=True)

    # Avant le report : un t-shirt sali cette nuit peut avancer l'échéance de
    # la lessive, et donc changer ce qu'il y a à replacer.
    ordonnanceur.add_job(consommer_l_uniforme, a(0, 2),
                         id="uniforme", name="Consommation de l'uniforme",
                         coalesce=True)

    ordonnanceur.add_job(report_de_minuit, a(0, 5),
                         id="report", name="Report d'office", coalesce=True)

    ordonnanceur.start()
    _ordonnanceur = ordonnanceur
    LOG.info("Ordonnanceur démarré (%s)", conf.fuseau)
    return ordonnanceur


def arreter() -> None:
    global _ordonnanceur
    if _ordonnanceur is not None:
        _ordonnanceur.shutdown(wait=False)
        _ordonnanceur = None


def taches_programmees() -> list[dict]:
    if _ordonnanceur is None:
        return []
    return [
        {
            "id": tache.id,
            "nom": tache.name,
            "prochaine_execution": tache.next_run_time.isoformat()
            if tache.next_run_time else None,
        }
        for tache in _ordonnanceur.get_jobs()
    ]
