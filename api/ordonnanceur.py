"""Déclenchement périodique : collectes, placement, notifications.

    toutes les heures   collecter les sources dont la fréquence est écoulée
    toutes les 2 h      relever les confirmations SNCF
    toutes les 6 h      calendriers personnels
    06h50               relevé des horaires publiés par le SUAPS
    07h00               placement du matin, semaine de sport à valider
    toutes les 5 min    à l'heure de chacun (NOT-15) : bilan du matin (7h par
                        défaut), relance du soir (21h), récap de HAL (23h) avec
                        la clôture du jour et la révision du dimanche
    chaque minute       changements à raconter (NOT-17), envoi par Apple (NOT-16)
    07h10               propositions de week-end
    07h20, le lundi     prévenir si le sport de la semaine n'est pas choisi
    toutes les 30 min   constater les séances à déterminer passées
    06h55               coach : rattrapage de la synthèse si elle a échoué
    toutes les 10 min   coach : ajustements restés sans réponse au début d'une séance
    00h05               report d'office de ce qui n'a pas été fait

Les heures ci-dessus sont des heures de Paris. Le conteneur, lui, vit en UTC :
tous les horodatages en base sont ainsi comparables, quelle que soit la saison.
C'est seulement à l'affichage et au déclenchement qu'on repasse à l'heure d'ici.

Chaque tâche appelle la même fonction que l'endpoint correspondant : le chemin
de nuit reste ainsi couvert par les tests de l'API.
"""

import logging
from datetime import datetime, timedelta
from functools import wraps
from zoneinfo import ZoneInfo

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger

from api import operation
from api.base import executer, lister
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

    # ABS-5 : un billet lu ouvre ou ferme une absence, et les tâches déjà
    # posées sur ces jours-là doivent partir ailleurs. Le placement sait le
    # faire, y compris dans la période gelée, mais encore faut-il l'appeler :
    # sans ça le planning reste faux jusqu'au lendemain matin, et la relance du
    # soir réclame un ménage dans un appartement vide.
    if bilan.get("traites"):
        placer()

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


def relever_les_horaires() -> list[dict]:
    """Les créneaux de la piscine, relevés sur la page du SUAPS.

    Tous les jours : le service change ses horaires d'une semaine à l'autre, et
    une séance proposée devant une porte close est pire que pas de séance.
    """
    from api import sport

    try:
        return sport.rafraichir_horaires()
    except Exception:
        LOG.exception("Échec du relevé des horaires")
        return []


def alerter_pour_le_sport() -> int:
    """SPT-27 : le lundi, prévenir si la semaine n'a pas ses séances choisies.

    Rien quand tout est choisi. Sinon ce qui manque, et ce qui est réservé en
    attendant, avec un bouton pour organiser.
    """
    from api import sport

    try:
        return sport.alerter_le_lundi()
    except Exception:
        LOG.exception("Échec de l'alerte de sport du lundi")
        return 0


def constater_le_sport() -> int:
    """SPT-25 : une séance à déterminer passée sans être choisie.

    Pas de « c'est fait ? » : un message le constate, et la semaine se complète
    sur un autre jour quand il en reste.
    """
    from api import sport

    try:
        manquees = sport.constater_les_manquees()
    except Exception:
        LOG.exception("Échec du constat des séances à déterminer")
        return 0
    if manquees:
        LOG.info("Sport : %s séance(s) à déterminer passée(s)", manquees)
    return manquees


def placer() -> int:
    conf = configuration()
    resultat = executer("SELECT placer_taches(%(h)s, %(s)s) AS placees",
                        {"h": conf.horizon_jours, "s": conf.stabilite_jours})
    placees = (resultat or {}).get("placees", 0)
    LOG.info("Placement : %s occurrence(s)", placees)
    return placees


def placement_du_matin() -> int:
    """7h, pour tout le foyer : le placement, et la semaine de sport à valider.

    NOT-15 : le placement reste commun. Le bilan, lui, part à l'heure de chacun.
    """
    placees = placer()
    # NOT-12 : la semaine de sport qui attend d'être validée.
    try:
        from api.coach import planifie
        planifie.matin()
    except Exception:
        LOG.exception("Échec du rappel de la semaine à valider")
    return placees


def bilan_du_matin() -> int:
    """Le bilan de tous, d'un coup : ce que fait la route d'administration."""
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


def servir(id_utilisateur: int, moment: str, jour) -> bool:
    """Un rendez-vous d'un compte, une seule fois par jour (NOT-15).

    Le passage est noté avant d'agir : deux passages simultanés ne servent pas
    deux fois. Un récap qui échoue a ses propres nouveaux essais (COA-11).
    """
    pris = executer(
        """INSERT INTO passage (id_utilisateur, moment, jour) VALUES (%(u)s, %(m)s, %(j)s)
           ON CONFLICT DO NOTHING RETURNING moment""",
        {"u": id_utilisateur, "m": moment, "j": jour})
    if pris is None:
        return False
    if moment == "bilan":
        executer("SELECT bilan_du_matin_de(%(u)s)", {"u": id_utilisateur})
    elif moment == "relance":
        executer("SELECT relance_du_soir_de(%(u)s)", {"u": id_utilisateur})
    elif moment == "recap":
        from api.coach import planifie
        planifie.soir(_programmer_essai, seulement={id_utilisateur})
    return True


def heures_de_chacun() -> int:
    """Toutes les cinq minutes : le bilan, la relance et le récap dus (NOT-15)."""
    servis = 0
    dus = lister("SELECT id_utilisateur, moment, jour FROM rendez_vous_dus()")
    if any(du["moment"] == "bilan" for du in dus):
        # Le bilan lit le planning du jour : il doit être posé. À 7h, le
        # placement du matin et ce passage tombent ensemble, dans un ordre
        # que rien ne garantit.
        placer()
    for du in dus:
        try:
            if servir(du["id_utilisateur"], du["moment"], du["jour"]):
                servis += 1
        except Exception:  # noqa: BLE001 - un compte ne prive pas l'autre
            LOG.exception("Rendez-vous %s impossible pour le compte %s",
                          du["moment"], du["id_utilisateur"])
    if servis:
        LOG.info("Heures de chacun : %s rendez-vous servi(s)", servis)
    return servis


def notifications_de_l_appli() -> dict:
    """Chaque minute : les changements à raconter (NOT-17), puis l'envoi par Apple."""
    from api import apple, changements
    bilan: dict = {}
    try:
        bilan["changements"] = changements.annoncer()
    except Exception:
        LOG.exception("Échec de l'annonce des changements")
    try:
        bilan.update(apple.envoyer_la_file())
    except Exception:
        LOG.exception("Échec de l'envoi par Apple")
    return bilan


def report_de_minuit() -> dict:
    """Reporte, abandonne ou alerte, selon le retard de chaque occurrence.

    EXE-12 : au-delà du délai propre à la tâche, l'occurrence est oubliée plutôt
    que reportée une fois de plus.
    """
    resultat = executer("SELECT reporter_taches_du_jour() AS bilan")
    bilan = (resultat or {}).get("bilan") or {}
    LOG.info("Report d'office : %s reportée(s), %s abandonnée(s), %s alerte(s)",
             bilan.get("reportees", 0), bilan.get("abandonnees", 0),
             bilan.get("alertes", 0))

    # COL-19 : un conflit dont le jour est passé ne s'arbitre plus. La vue
    # cesse déjà de le proposer ; on le referme pour que la table ne garde pas
    # indéfiniment des questions sans réponse possible.
    perimes = (executer("SELECT perimer_les_conflits() AS nombre") or {}).get("nombre", 0)
    if perimes:
        LOG.info("Conflits périmés : %s", perimes)
    bilan["conflits_perimes"] = perimes

    # JRN-8 : le journal ne garde que trois mois.
    purges = (executer("SELECT purger_journal() AS nombre") or {}).get("nombre", 0)
    if purges:
        LOG.info("Journal : %s événement(s) purgé(s)", purges)
    bilan["journal_purge"] = purges

    # MES-3, PAU-6 : les fenêtres de mesure expirées, les pauses arrivées à
    # leur terme.
    try:
        from api.coach import planifie
        bilan["coach"] = planifie.minuit()
    except Exception:
        LOG.exception("Échec du passage de minuit du coach")

    return bilan


# ---------------------------------------------------------------------------
# Le coach
# ---------------------------------------------------------------------------

def _programmer_essai(minutes: int, id_utilisateur: int, moment: str,
                      operation_id: str, essai: int) -> None:
    """COA-11 : un nouvel essai, à 5, 20 puis 50 minutes après 23 h."""
    if _ordonnanceur is None:
        return
    from apscheduler.triggers.date import DateTrigger

    conf = configuration()
    quand = datetime.now(ZoneInfo(conf.fuseau)) + timedelta(minutes=minutes)
    _ordonnanceur.add_job(
        essai_du_coach, DateTrigger(run_date=quand, timezone=conf.fuseau),
        args=[id_utilisateur, moment, operation_id, essai],
        id=f"coach_essai_{id_utilisateur}_{essai}", name=f"Synthèse du coach, essai {essai}",
        replace_existing=True)


def soir_du_coach() -> dict:
    """23 h : clôture du jour, puis synthèse du soir. Révision le dimanche."""
    from api.coach import planifie
    try:
        bilan = planifie.soir(_programmer_essai)
    except Exception:
        LOG.exception("Échec du soir du coach")
        return {}
    if bilan:
        LOG.info("Soir du coach : %s", bilan)
    return bilan


def essai_du_coach(id_utilisateur: int, moment: str, operation_id: str, essai: int) -> bool:
    from api.coach import planifie
    try:
        return planifie.nouvel_essai(id_utilisateur, moment, operation_id, essai,
                                     _programmer_essai)
    except Exception:
        LOG.exception("Échec d'un nouvel essai du coach")
        return False


def rattrapage_du_coach() -> dict:
    """6h55 : la synthèse de la veille, si les trois essais ont échoué."""
    from api.coach import planifie
    try:
        return planifie.rattrapage()
    except Exception:
        LOG.exception("Échec du rattrapage du coach")
        return {}


def ajustements_du_coach() -> int:
    """PLN-19 : au début d'une séance, le silence ne peut qu'alléger."""
    try:
        return (executer("SELECT solder_ajustements() AS n") or {}).get("n", 0)
    except Exception:
        LOG.exception("Échec du solde des ajustements")
        return 0


class _Suivi(BackgroundScheduler):
    """JRN-4 : chaque tâche planifiée est une action du journal, à son nom.

    Le nom est celui donné à `add_job` : « Bilan du matin », « Report d'office ».
    C'est ce qu'on lira à côté de ce que la tâche a changé.
    """

    def add_job(self, func, *args, **kwargs):
        nom = kwargs.get("name") or func.__name__

        @wraps(func)
        def suivie(*a, **k):
            with operation.ouvrir(nom, acteur="ordonnanceur"):
                return func(*a, **k)

        return super().add_job(suivie, *args, **kwargs)


def demarrer() -> BackgroundScheduler:
    global _ordonnanceur
    if _ordonnanceur is not None:
        return _ordonnanceur

    conf = configuration()
    ordonnanceur = _Suivi(timezone=conf.fuseau)

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

    # Avant le bilan : les horaires du jour doivent être à jour quand le
    # placement tourne.
    ordonnanceur.add_job(relever_les_horaires, a(6, 50),
                         id="horaires", name="Relevé des horaires de sport",
                         coalesce=True)

    # NOT-15 : le placement reste commun, à 7h. Le bilan, la relance et le
    # récap partent à l'heure de chacun : un passage toutes les cinq minutes.
    ordonnanceur.add_job(placement_du_matin, a(7, 0),
                         id="placement", name="Placement du matin", coalesce=True)
    ordonnanceur.add_job(heures_de_chacun, CronTrigger(minute="*/5", timezone=conf.fuseau),
                         id="heures", name="Heures de chacun",
                         max_instances=1, coalesce=True)
    ordonnanceur.add_job(notifications_de_l_appli, IntervalTrigger(minutes=1),
                         id="appli", name="Notifications de l'appli",
                         max_instances=1, coalesce=True)

    # Après le bilan du matin : on lit ses messages une fois, et la
    # proposition arrive dans la même fournée que le reste.
    ordonnanceur.add_job(proposer_les_weekends, a(7, 10),
                         id="weekends", name="Propositions de week-end",
                         coalesce=True)

    # Lundi seulement, juste après le bilan : la semaine vient de commencer et
    # c'est le moment où on l'organise.
    ordonnanceur.add_job(alerter_pour_le_sport,
                         CronTrigger(day_of_week="mon", hour=7, minute=20,
                                     timezone=conf.fuseau),
                         id="sport", name="Alerte de sport du lundi",
                         coalesce=True)

    # Une réservation passée se constate vite, pour que le message arrive quand
    # on peut encore caser la séance ailleurs dans la journée.
    ordonnanceur.add_job(constater_le_sport, IntervalTrigger(minutes=30),
                         id="sport_manque", name="Séances à déterminer passées",
                         max_instances=1, coalesce=True)

    # Le coach. La synthèse part à l'heure du récap de chacun (heures_de_chacun),
    # clôture du jour comprise. Les nouveaux essais se programment d'eux-mêmes
    # après un échec.
    ordonnanceur.add_job(rattrapage_du_coach, a(6, 55),
                         id="coach_rattrapage", name="Rattrapage de la synthèse du coach",
                         coalesce=True)
    ordonnanceur.add_job(ajustements_du_coach, IntervalTrigger(minutes=10),
                         id="coach_ajustements", name="Ajustements sans réponse",
                         max_instances=1, coalesce=True)
    ordonnanceur.add_job(report_de_minuit, a(0, 5),
                         id="report", name="Report d'office", coalesce=True)

    ordonnanceur.start()
    _ordonnanceur = ordonnanceur
    # COA-22 : un appel resté en cours après un arrêt brutal bloquerait le compte.
    try:
        from api.coach import appel
        appel.liberer_les_appels_bloques()
    except Exception:
        LOG.exception("Impossible de libérer les appels au coach restés en cours")
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
