"""Le bot d'administration : ce qu'il dit et ce qu'il surveille.  (ADM-1 à ADM-5)

Les membres du foyer ont tout dans l'appli. Le bot ne parle plus qu'à
l'administrateur du serveur : l'état du serveur, les erreurs, les alertes.
Ce module se teste sans parler à Telegram ; `bot.py` ne fait que brancher.
"""

from __future__ import annotations

import html
import logging
import shutil
import threading
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

from api.base import executer, lister, un_seul
from api.config import configuration

LOG = logging.getLogger(__name__)

# ADM-1 : tout ce qu'un autre compte reçoit.
PHRASE_AUX_MEMBRES = ("Ce bot sert à l'administration du serveur. "
                      "Tout le reste se fait dans l'appli HAL.")

# Au-delà, les erreurs de l'API ne sont plus un accident : on prévient.
ERREURS_AVANT_ALERTE = 5
FENETRE_DES_ERREURS = timedelta(minutes=10)
# Le disque : on prévient à 90 %, on lève l'alerte sous 85 %.
DISQUE_ALERTE = 0.90
DISQUE_RETOUR = 0.85
# Les connexions à la base, en part du maximum permis.
CONNEXIONS_ALERTE = 0.90


def h(texte) -> str:
    return html.escape(str(texte), quote=False)


def _fuseau() -> ZoneInfo:
    return ZoneInfo(configuration().fuseau)


def _maintenant() -> datetime:
    return datetime.now(_fuseau())


def _quand(instant: datetime | None) -> str:
    if instant is None:
        return "jamais"
    return instant.astimezone(_fuseau()).strftime("%d/%m à %Hh%M")


# ---------------------------------------------------------------------------
# Les dernières erreurs                                                 (ADM-3)
#
# Écrites en base, dans erreur_recente : l'API et le travailleur sont deux
# processus, et le bot, qui vit dans le second, doit voir aussi les erreurs du
# premier. Elles ne restent qu'une journée : /erreurs dit ce qui casse
# maintenant, pas l'histoire du serveur.
#
# Chaque erreur s'écrit par une connexion à part, hors du pool et en
# autocommit : une erreur arrivée dans une transaction annulée reste notée, et
# un pool épuisé n'empêche pas de la noter. Base injoignable : l'erreur n'est
# pas notée, et la surveillance de la base le dira.
# ---------------------------------------------------------------------------

# Après un échec d'écriture, on n'essaie plus pendant ce temps : sans cela,
# chaque erreur d'une base tombée attendrait son délai de connexion.
PAUSE_APRES_ECHEC = timedelta(seconds=30)


class _Memoire(logging.Handler):
    """Note chaque erreur écrite au journal, avec le processus où elle arrive."""

    def __init__(self) -> None:
        super().__init__(level=logging.ERROR)
        self.processus = "api"
        self._connexion: psycopg.Connection | None = None
        self._en_pause_jusqu_a: datetime | None = None
        self._dedans = threading.local()

    def emit(self, record: logging.LogRecord) -> None:
        # Une erreur levée en notant une erreur ne se note pas à son tour.
        if getattr(self._dedans, "oui", False):
            return
        self._dedans.oui = True
        try:
            self._noter(record)
        except Exception:  # noqa: BLE001 - noter une erreur ne doit rien casser
            self._oublier_la_connexion()
            self._en_pause_jusqu_a = _maintenant() + PAUSE_APRES_ECHEC
        finally:
            self._dedans.oui = False

    def _noter(self, record: logging.LogRecord) -> None:
        try:
            message = record.getMessage().strip().splitlines()[0][:300]
        except Exception:  # noqa: BLE001 - un message illisible reste une erreur
            message = str(record.msg)[:300]
        if record.exc_info and record.exc_info[1] is not None:
            erreur = record.exc_info[1]
            message += f" ({type(erreur).__name__} : {str(erreur).strip()[:200]})"
        with _verrou:
            if self._en_pause_jusqu_a and _maintenant() < self._en_pause_jusqu_a:
                return
            if self._connexion is None or self._connexion.closed:
                self._connexion = psycopg.connect(configuration().url_base, autocommit=True,
                                                  connect_timeout=3)
            self._connexion.execute(
                """INSERT INTO erreur_recente (quand, processus, module, message)
                   VALUES (to_timestamp(%s), %s, left(%s, 120), %s)""",
                (record.created, self.processus, record.name, message))
            self._connexion.execute(
                "DELETE FROM erreur_recente WHERE quand < now() - INTERVAL '1 day'")
            self._en_pause_jusqu_a = None

    def _oublier_la_connexion(self) -> None:
        if self._connexion is not None:
            try:
                self._connexion.close()
            except Exception:  # noqa: BLE001
                pass
        self._connexion = None


_verrou = threading.Lock()
_memoire = _Memoire()


def installer(processus: str = "api") -> None:
    """Branche la mémoire des erreurs sur le journal du processus. Une seule fois."""
    _memoire.processus = processus
    racine = logging.getLogger()
    if _memoire not in racine.handlers:
        racine.addHandler(_memoire)


def dernieres_erreurs(nombre: int = 10) -> list[dict]:
    return lister("""SELECT quand, processus, module, message FROM erreur_recente
                      ORDER BY id_erreur DESC LIMIT %(n)s""", {"n": nombre})


def erreurs_recentes(fenetre: timedelta = FENETRE_DES_ERREURS) -> int:
    ligne = un_seul("SELECT count(*)::INTEGER AS n FROM erreur_recente "
                    "WHERE quand >= now() - %(f)s", {"f": fenetre})
    return (ligne or {}).get("n", 0)


def oublier_les_erreurs() -> None:
    executer("DELETE FROM erreur_recente")


# ---------------------------------------------------------------------------
# Prévenir                                                       (ADM-2, ADM-4)
# ---------------------------------------------------------------------------

def notifications_a_envoyer(limite: int = 20) -> list[dict]:
    """Les alertes de l'administration qui attendent le bot (ADM-2, ADM-5).

    Le bot ne transporte plus rien d'autre : les notifications des membres,
    celles de l'administrateur comprises, passent par l'appli. Une alerte part
    à toute heure : un serveur en panne n'attend pas le matin.
    """
    return lister(
        """
        SELECT n.id_notification, n.id_utilisateur, u.id_telegram, n.type, n.contenu
          FROM notification n
          JOIN utilisateur u ON u.id_utilisateur = n.id_utilisateur
         WHERE n.statut = 'a_envoyer'
           AND n.type = 'administration'
           AND u.role = 'admin' AND u.actif
           AND u.id_telegram IS NOT NULL
         ORDER BY n.date_creation
         LIMIT %(limite)s
        """,
        {"limite": limite},
    )


def marquer_envoyee(id_notification: int, reussi: bool = True) -> None:
    executer(
        """
        UPDATE notification
           SET statut     = CASE WHEN %(ok)s THEN 'envoyee' ELSE 'echec' END,
               date_envoi = CASE WHEN %(ok)s THEN now() ELSE date_envoi END
         WHERE id_notification = %(id)s
        """,
        {"id": id_notification, "ok": reussi},
    )


def alerter(cle: str, texte: str) -> bool:
    """Un problème. La base décide s'il faut le redire : une fois par heure au plus.

    Jamais d'exception : une alerte qui casse ne doit pas casser ce qui l'a vue.
    """
    try:
        ligne = executer("SELECT alerter_l_administrateur(%(c)s, %(t)s) AS envoyee",
                         {"c": cle, "t": texte})
        return bool(ligne and ligne["envoyee"])
    except Exception as erreur:  # noqa: BLE001
        LOG.warning("Alerte %s non enregistrée : %s", cle, erreur)
        return False


def lever(cle: str, texte: str) -> bool:
    """Le problème est réglé : le bot le dit, s'il l'avait annoncé."""
    try:
        ligne = executer("SELECT lever_l_alerte(%(c)s, %(t)s) AS envoyee",
                         {"c": cle, "t": texte})
        return bool(ligne and ligne["envoyee"])
    except Exception as erreur:  # noqa: BLE001
        LOG.warning("Alerte %s non levée : %s", cle, erreur)
        return False


def apres_l_envoi_par_apple(bilan: dict) -> None:
    """ADM-2 : des notifications qu'Apple refuse."""
    if bilan.get("echecs"):
        alerter("apple", f"⚠️ Apple a refusé {bilan['echecs']} notification(s) après "
                         "tous les essais. Vérifier la clé APNs et le sujet.")
    elif bilan.get("envoyees"):
        lever("apple", "✅ Apple accepte de nouveau les notifications.")


def hal_injoignable(pseudo: str) -> None:
    """ADM-2, COA-11 : HAL n'a pas répondu, même après ses nouveaux essais."""
    alerter("hal", f"⚠️ HAL est resté injoignable pour {pseudo} après tous ses essais.")


def hal_repond() -> None:
    lever("hal", "✅ HAL répond de nouveau.")


def _sources() -> None:
    """COL-9 : une source qui ne se collecte plus."""
    for s in lister("""SELECT code, libelle, etat_calcule, derniere_collecte
                         FROM v_source_sante
                        WHERE active AND mode_collecte <> 'manuelle'"""):
        cle = f"source:{s['code']}"
        if s["etat_calcule"] == "en_panne":
            alerter(cle, f"⚠️ La source {s['libelle']} ({s['code']}) ne se collecte plus. "
                         f"Dernière collecte réussie : {_quand(s['derniere_collecte'])}.")
        else:
            lever(cle, f"✅ La source {s['libelle']} ({s['code']}) se collecte de nouveau.")


def _erreurs_de_l_api() -> None:
    nombre = erreurs_recentes()
    if nombre >= ERREURS_AVANT_ALERTE:
        derniere = dernieres_erreurs(1)[0]["message"]
        alerter("api", f"⚠️ {nombre} erreurs de l'API en dix minutes. "
                       f"La dernière : {derniere}\n/erreurs pour le détail.")
    elif erreurs_recentes(timedelta(minutes=30)) == 0:
        lever("api", "✅ Plus d'erreur de l'API depuis une demi-heure.")


def _disque() -> None:
    usage = shutil.disk_usage("/")
    part = usage.used / usage.total if usage.total else 0
    if part >= DISQUE_ALERTE:
        alerter("disque", f"⚠️ Le disque est plein à {part:.0%} "
                          f"({usage.free // 2**30} Go libres).")
    elif part < DISQUE_RETOUR:
        lever("disque", f"✅ Le disque respire de nouveau ({part:.0%}).")


def _base() -> None:
    ligne = un_seul("""SELECT count(*)::INTEGER AS ouvertes,
                              current_setting('max_connections')::INTEGER AS maximum
                         FROM pg_stat_activity""")
    if not ligne or not ligne["maximum"]:
        return
    part = ligne["ouvertes"] / ligne["maximum"]
    if part >= CONNEXIONS_ALERTE:
        alerter("base", f"⚠️ La base sature : {ligne['ouvertes']} connexions ouvertes "
                        f"sur {ligne['maximum']}.")
    else:
        lever("base", "✅ La base a de nouveau des connexions libres.")


def surveiller() -> list[str]:
    """Le passage de l'ordonnanceur : ce qui ne dépend d'aucun événement.

    Chaque vérification est indépendante : une qui casse laisse passer les autres.
    """
    ratees = []
    for verification in (_sources, _erreurs_de_l_api, _disque, _base):
        try:
            verification()
        except Exception as erreur:  # noqa: BLE001
            # Un avertissement, pas une erreur : sinon la surveillance
            # alimenterait elle-même le compte des erreurs de l'API.
            LOG.warning("Surveillance %s impossible : %s", verification.__name__, erreur)
            ratees.append(verification.__name__)
    return ratees


# ---------------------------------------------------------------------------
# Ce que le bot répond                                                  (ADM-3)
# ---------------------------------------------------------------------------

def est_administrateur(compte: dict | None) -> bool:
    return bool(compte) and compte.get("role") == "admin"


def etat(taches: list[dict] | None = None, bot: dict | None = None) -> str:
    """/etat : le serveur, les sources, le dernier déploiement, les alertes en cours."""
    conf = configuration()
    lignes = [f"<b>Serveur</b> : version {h(conf.version)}"]
    try:
        un_seul("SELECT 1 AS ok")
        lignes.append("Base : répond")
    except Exception as erreur:  # noqa: BLE001
        lignes.append(f"Base : <b>injoignable</b> ({h(erreur)})")
        return "\n".join(lignes)

    if taches is not None:
        lignes.append(f"Ordonnanceur : {len(taches)} tâche(s) programmée(s)"
                      if taches else "Ordonnanceur : <b>arrêté</b>")
    usage = shutil.disk_usage("/")
    if usage.total:
        lignes.append(f"Disque : {usage.used / usage.total:.0%} utilisé")

    deploiement = un_seul("""SELECT quand, libelle FROM evenement
                              WHERE objet = 'deploiement'
                              ORDER BY id_evenement DESC LIMIT 1""")
    if deploiement:
        lignes.append(f"Dernier déploiement : {_quand(deploiement['quand'])}, "
                      f"{h(deploiement['libelle'] or '')}")

    sources = lister("""SELECT code, etat_calcule, derniere_collecte
                          FROM v_source_sante
                         WHERE active ORDER BY code""")
    if sources:
        lignes.append("\n<b>Sources</b>")
        for s in sources:
            marque = "⚠️ en panne" if s["etat_calcule"] == "en_panne" else "ok"
            lignes.append(f"• {h(s['code'])} : {marque}, "
                          f"collectée {_quand(s['derniere_collecte'])}")

    ouvertes = lister("""SELECT cle, texte, ouverte_le FROM alerte_admin
                          WHERE reglee_le IS NULL ORDER BY ouverte_le""")
    lignes.append("\n<b>Alertes en cours</b>" if ouvertes else "\nAucune alerte en cours.")
    for a in ouvertes:
        lignes.append(f"• depuis le {_quand(a['ouverte_le'])} : {h(a['texte'])}")

    nombre = erreurs_recentes(timedelta(hours=1))
    if nombre:
        lignes.append(f"\n{nombre} erreur(s) dans l'heure : /erreurs")
    return "\n".join(lignes)


def erreurs_en_clair(nombre: int = 10) -> str:
    """/erreurs : les dernières erreurs, de la plus récente à la plus ancienne."""
    erreurs = dernieres_erreurs(nombre)
    if not erreurs:
        return "Aucune erreur dans les dernières vingt-quatre heures."
    lignes = ["<b>Dernières erreurs</b>"]
    for e in erreurs:
        ou = " (travailleur)" if e["processus"] == "travailleur" else ""
        lignes.append(f"• {_quand(e['quand'])}, {h(e['module'])}{ou} : {h(e['message'])}")
    return "\n".join(lignes)


def hal_en_clair() -> str:
    """/hal : l'état de HAL par compte, et ce qu'il a consommé en sept jours."""
    comptes = lister(
        """SELECT u.id_utilisateur, u.pseudo, u.coach_actif,
                  COALESCE(sum(c.appels), 0)::INTEGER     AS appels,
                  COALESCE(sum(c.echecs), 0)::INTEGER     AS echecs,
                  COALESCE(sum(c.tokens_entree), 0)::BIGINT AS entree,
                  COALESCE(sum(c.tokens_cache), 0)::BIGINT  AS cache,
                  COALESCE(sum(c.tokens_sortie), 0)::BIGINT AS sortie,
                  COALESCE(sum(c.cout_usd), 0)::NUMERIC(10, 2) AS cout
             FROM utilisateur u
             LEFT JOIN v_cout_coach c
                    ON c.id_utilisateur = u.id_utilisateur AND c.jour > jour_de(now()) - 7
            WHERE u.actif
            GROUP BY u.id_utilisateur, u.pseudo, u.coach_actif
            ORDER BY u.pseudo""")
    if not comptes:
        return "Aucun compte actif."
    lignes = ["<b>HAL, sept derniers jours</b>"]
    total = 0.0
    for c in comptes:
        etat_hal = "activé" if c["coach_actif"] else "coupé"
        lignes.append(f"• <b>{h(c['pseudo'])}</b> : {etat_hal}, {c['appels']} appel(s), "
                      f"{c['echecs']} échec(s), {c['entree']} tokens lus dont "
                      f"{c['cache']} du cache, {c['sortie']} écrits, {c['cout']} $")
        total += float(c["cout"])
    lignes.append(f"\nTotal : {total:.2f} $")
    lignes.append("<code>/hal pseudo on</code> ou <code>/hal pseudo off</code> : "
                  "activer ou couper HAL pour un compte.")
    return "\n".join(lignes)


def regler_hal(pseudo: str, actif: bool) -> str:
    """COA-1 : HAL s'active ou se coupe par compte, depuis le bot d'administration."""
    cible = un_seul("SELECT id_utilisateur, pseudo FROM utilisateur WHERE pseudo = %(p)s",
                    {"p": pseudo.strip().lower()})
    if cible is None:
        return f"Compte inconnu : {h(pseudo)}."
    executer("SELECT activer_coach(%(u)s, %(a)s)",
             {"u": cible["id_utilisateur"], "a": actif})
    return f"HAL est {'activé' if actif else 'coupé'} pour {h(cible['pseudo'])}."
