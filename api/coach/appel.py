"""Un appel au coach, du déclencheur à la réponse            (opération C1)

Le modèle ne retient rien d'un appel à l'autre et ne peut rien faire seul. Le
module lui envoie une consigne et la liste des outils permis pour ce moment,
exécute les outils qu'il demande, et recommence jusqu'à ce qu'il rende un
texte. Il ne décide de rien : il transmet.

    1. un seul appel en cours par compte, l'appel est enregistré      (COA-21, COA-22)
    2. une opération du journal à lui, sous l'acteur « coach »        (COA-6)
    3. la consigne : dossier, contexte, derniers échanges, moment     (COA-3)
    4. la boucle, bornée en tours et en temps                         (COA-7, COA-16)
    5. la réponse : le texte du modèle, et ce que la base a écrit     (COA-17, COA-18)
    6. l'échange et la notification, écrits ensemble                  (CAR-6, NOT-11)
"""

import logging
import time
import uuid
from dataclasses import dataclass, field

import psycopg
from psycopg.types.json import Jsonb

from api import operation
from api.base import connexion, executer, lister, un_seul
from api.coach import contexte, dossier, modele, outils, reponse
from api.coach.clair import clair, jour_en_clair, maintenant
from api.config import configuration

LOG = logging.getLogger(__name__)

# Les moments qui construisent beaucoup : trente tours au lieu de douze (COA-7).
MOMENTS_LONGS = ("plan", "revision")


class EchecAppel(Exception):
    """Un appel planifié qui n'a pas abouti : l'ordonnanceur réessaiera (COA-11)."""

    def __init__(self, motif: str, operation_id: str, essai: int):
        super().__init__(motif)
        self.motif = motif
        self.operation_id = operation_id
        self.essai = essai


class CoachInactif(Exception):
    """COA-1 : le compte n'a pas le coach."""


@dataclass
class Demande:
    id_utilisateur: int
    moment: str
    declencheur: str = "utilisateur"          # ordonnanceur, utilisateur, systeme
    texte: str | None = None                  # ce que l'utilisateur a écrit, tel quel
    id_occurrence: int | None = None
    cle_client: str | None = None
    # Ce que la situation a de particulier, dit au modèle avec le moment.
    precision: str | None = None
    # COA-24 : un nouvel essai garde le numéro d'opération de l'appel échoué.
    operation_id: str | None = None
    essai: int = 1
    # Le bot affiche lui-même la réponse à une demande venue de Telegram : la
    # notification est alors écrite déjà envoyée, pour ne pas la montrer deux fois.
    deja_affichee: bool = False
    # PAU-6 : à la reprise, la révision retrouve ses outils de séance.
    extra: dict = field(default_factory=dict)


def _moment_du(demande: Demande, deja_ecrit: list[dict]) -> str:
    """Le message du moment : ce qui déclenche l'appel, et ce qu'on attend."""
    m = demande.moment
    jour = maintenant()
    lignes = [f"# Moment : {m}",
              f"{jour_en_clair(jour.date())} {jour.year}, {jour:%H:%M}."]

    if m == "faisabilite":
        lignes.append(
            "Un objectif vient d'être créé ou modifié. Lis le niveau actuel, les mesures et "
            "l'emploi du temps des semaines à venir, puis rends ton avis avec `rendre_avis` : "
            "réaliste, ambitieux ou irréaliste, avec l'ajustement que tu proposes. Faute de "
            "données pour juger, dis-le et propose un test. Si les objectifs sont trop "
            "nombreux ou se contredisent, dis lequel tu mettrais en pause : tu ne le fais "
            "jamais toi-même.")
    elif m == "plan":
        lignes.append(
            "Construis le plan de quatre semaines à partir de l'objectif principal. Dans "
            "l'ordre : écris ou révise la feuille de route, crée le plan avec `ecrire_trame` "
            "(nouveau_plan à vrai), lis la charge de chaque journée sur quatre semaines avec "
            "`lire_planning`, puis propose les séances. La première semaine est détaillée, "
            "avec ses exercices. Les trois autres sont des esquisses : un jour, un lieu, un "
            "type, une durée, une intensité, sans exercices. Ouvre les fenêtres de mesure "
            "utiles à l'objectif. Termine en annonçant le plan et en demandant la validation "
            "de la première semaine. Si l'emploi du temps n'est pas connu au-delà de deux "
            "semaines, ne place que ce que tu sais.")
    elif m == "revision":
        lignes.append(
            "C'est la synthèse du soir et la révision de la semaine. Fais d'abord la "
            "synthèse de la journée. Puis révise les esquisses des semaines suivantes selon "
            "l'emploi du temps et la forme, détaille la première semaine qui n'est pas "
            "validée (ses exercices, avec `modifier_seance_proposee`), et propose-la à la "
            "validation. Relis le carnet : fusionne les doublons, retire ce qui est périmé. "
            "Si le plan est arrivé à son terme, construis le suivant dans ce même appel.")
    elif m == "synthese":
        lignes.append(
            "C'est la synthèse du soir. Elle couvre la journée entière : séances faites, pas "
            "faites ou non validées, données de santé et leur fraîcheur, mesures attendues, "
            "déplacements faits par l'utilisateur, objectifs échus, séances faites sans "
            "bilan. Pour chaque séance pas faite, décide : une séance clé est proposée à "
            "nouveau s'il reste un jour qui tient, une séance secondaire est abandonnée. "
            "Pour chaque séance libre du jour, rends un avis puis compense ou allège la "
            "suite. Note au carnet ce qui est durable. Termine par ce qui attend demain. Un "
            "jour sans rien à dire donne une synthèse courte, pas un silence.")
    elif m == "bilan":
        lignes.append(
            "L'utilisateur vient de clore une séance et demande ton bilan tout de suite. Lis "
            "la séance, compare ce qui a été fait à ce qui était prévu, et réponds.")
    elif m == "signalement":
        lignes.append(
            "L'utilisateur signale quelque chose : une douleur, une fatigue, un contretemps, "
            "une séance libre annoncée, ou la réponse à une question que tu avais posée. "
            "Applique d'abord le chapitre 1.2, puis le chapitre 8.4 ou 7.4 selon le cas. Tu "
            "peux retirer ou modifier des séances proposées. Sur une séance validée, tu "
            "déposes un ajustement. Note au carnet ce qui doit être retenu.")
    elif m == "chat":
        lignes.append(
            "L'utilisateur pose une question. Réponds-y, en lisant les chapitres et les "
            "données utiles. Tu ne disposes pas des outils de séance : ce qui touche au plan "
            "attend la synthèse du soir. MAIS si son texte est en fait un signalement (une "
            "douleur, une fatigue, un contretemps) ou la réponse à une question que tu as "
            "posée dans une synthèse, appelle d'abord `requalifier_en_signalement`.")

    if demande.precision:
        lignes.append(demande.precision)
    if demande.id_occurrence:
        lignes.append(f"La séance dont on parle : id_occurrence {demande.id_occurrence}.")
    if deja_ecrit:
        # COA-24 : un nouvel essai termine, il ne recommence pas.
        lignes.append(
            f"ATTENTION : ceci est l'essai n° {demande.essai}. L'essai précédent s'est "
            "interrompu, mais ce qu'il a écrit est resté. Ne le refais pas : vérifie avec "
            "tes outils de lecture, termine ce qui manque, puis rédige ton message. Déjà "
            "écrit par cette opération : " + _resume(deja_ecrit))
    if demande.texte:
        lignes.append("\n# Message de l'utilisateur\n" + demande.texte)
    return "\n\n".join(lignes)


def _resume(elements: list[dict]) -> str:
    import json
    allege = [{cle: v for cle, v in e.items() if cle != "actions"} for e in elements]
    return json.dumps(allege, ensure_ascii=False)


def derniers_echanges(id_utilisateur: int) -> str:
    """CAR-7 : les derniers échanges, du plus ancien au plus récent."""
    lignes = lister(
        """SELECT quand, auteur, moment, contenu FROM (
               SELECT e.id_echange, e.quand, e.auteur, e.moment, e.contenu
                 FROM echange e WHERE e.id_utilisateur = %(u)s
                ORDER BY e.id_echange DESC LIMIT %(n)s) x
            ORDER BY id_echange""",
        {"u": id_utilisateur, "n": configuration().coach_echanges_rendus})
    if not lignes:
        return "# Derniers échanges\n\nAucun échange pour l'instant : c'est le premier."
    morceaux = ["# Derniers échanges (du plus ancien au plus récent)"]
    for ligne in lignes:
        qui = {"utilisateur": "Utilisateur", "coach": "Toi",
               "systeme": "Message automatique"}[ligne["auteur"]]
        morceaux.append(f"[{clair(ligne['quand'])}, {ligne['moment']}] {qui} : "
                        f"{ligne['contenu']}")
    return "\n\n".join(morceaux)


def consigne(id_utilisateur: int) -> list[dict]:
    """La consigne, du plus stable au plus changeant.

    Le fournisseur facture moins cher une partie déjà vue : la partie fixe vient
    donc en premier et reste identique d'un appel à l'autre, au caractère près.
    """
    return [
        {"type": "text", "text": dossier.consigne() + "\n\n" + dossier.base(),
         "cache_control": {"type": "ephemeral"}},
        {"type": "text", "text": contexte.texte(id_utilisateur),
         "cache_control": {"type": "ephemeral"}},
    ]


# ---------------------------------------------------------------------------
# L'enregistrement de l'appel
# ---------------------------------------------------------------------------

def _echange_de_l_appel(id_appel: int) -> dict | None:
    return un_seul(
        """SELECT e.id_echange, e.moment, e.auteur, e.contenu, e.elements, e.quand
             FROM echange e
            WHERE e.id_appel = %(a)s AND e.auteur IN ('coach', 'systeme')
            ORDER BY e.id_echange DESC LIMIT 1""", {"a": id_appel})


def _deja_demande(demande: Demande, delai: float) -> dict | None:
    """COA-26 : la même clé d'appareil ne rappelle pas le modèle.

    Elle rend l'échange déjà produit, ou attend l'appel encore en cours.
    """
    if not demande.cle_client:
        return None
    limite = time.monotonic() + delai
    while True:
        appel = un_seul("SELECT id_appel, statut FROM appel_coach WHERE cle_client = %(c)s "
                        "AND id_utilisateur = %(u)s",
                        {"c": demande.cle_client, "u": demande.id_utilisateur})
        if appel is None:
            return None
        if appel["statut"] != "en_cours":
            echange = _echange_de_l_appel(appel["id_appel"])
            if echange is not None:
                return reponse.depuis_echange(echange)
            return {"id_echange": None, "moment": demande.moment, "auteur": "systeme",
                    "message": reponse.MESSAGE_INJOIGNABLE, "elements": []}
        if time.monotonic() >= limite:
            return {"id_echange": None, "moment": demande.moment, "auteur": "systeme",
                    "message": reponse.MESSAGE_INJOIGNABLE, "elements": []}
        time.sleep(1.0)


def _ouvrir_appel(demande: Demande, operation_id: str, delai: float) -> int | None:
    """COA-22 : un compte n'a qu'un appel en cours. Un deuxième attend le premier.

    L'index unique de la table est le verrou. Rend None si le premier n'a pas
    fini dans le délai.
    """
    limite = time.monotonic() + delai
    while True:
        try:
            ligne = executer(
                """INSERT INTO appel_coach (id_utilisateur, moment, declencheur, operation,
                                            essai, cle_client, modele)
                   VALUES (%(u)s, %(m)s, %(d)s, %(o)s, %(e)s, %(c)s, %(mo)s)
                   RETURNING id_appel""",
                {"u": demande.id_utilisateur, "m": demande.moment,
                 "d": demande.declencheur, "o": operation_id, "e": demande.essai,
                 "c": demande.cle_client, "mo": configuration().coach_modele})
            return ligne["id_appel"]
        except psycopg.errors.UniqueViolation:
            if time.monotonic() >= limite:
                return None
            time.sleep(1.0)


def _clore_appel(id_appel: int, statut: str, compte: dict, motif: str | None = None) -> None:
    executer(
        """UPDATE appel_coach
              SET statut = %(s)s, fin = now(), tours = %(t)s, tokens_entree = %(e)s,
                  tokens_cache = %(c)s, tokens_sortie = %(so)s, motif_echec = %(m)s,
                  moment = %(mo)s, deroule = %(d)s
            WHERE id_appel = %(a)s""",
        {"s": statut, "a": id_appel, "t": compte["tours"], "e": compte["entree"],
         "c": compte["cache"], "so": compte["sortie"], "m": motif, "mo": compte["moment"],
         "d": Jsonb(compte["deroule"])})


def _enregistrer(demande: Demande, moment: str, auteur: str, message: str,
                 elements: list[dict], operation_id: str | None,
                 id_appel: int | None) -> dict:
    """L'échange et sa notification, dans une même transaction (COA-16, NOT-2).

    Écrits avant que la réponse soit rendue : une réponse perdue en route se
    relit dans les échanges et arrive aussi par le bot.
    """
    conf = configuration()
    with connexion() as conn, conn.cursor() as cur:
        cur.execute(
            """INSERT INTO echange (id_utilisateur, auteur, moment, contenu, id_occurrence,
                                    operation, modele, version_dossier, elements, id_appel)
               VALUES (%(u)s, %(a)s, %(m)s, %(c)s, %(o)s, %(op)s, %(mo)s, %(v)s, %(e)s, %(ap)s)
               RETURNING id_echange, moment, auteur, contenu, elements, quand""",
            {"u": demande.id_utilisateur, "a": auteur, "m": moment, "c": message,
             "o": demande.id_occurrence, "op": operation_id,
             "mo": conf.coach_modele if auteur == "coach" else None,
             "v": dossier.version() if auteur == "coach" else None,
             "e": Jsonb(elements), "ap": id_appel})
        echange = cur.fetchone()
        cur.execute(
            """INSERT INTO notification (id_utilisateur, type, contenu, id_echange,
                                         statut, date_envoi)
               VALUES (%(u)s, 'coach', %(c)s, %(e)s,
                       CASE WHEN %(vu)s THEN 'envoyee' ELSE 'a_envoyer' END,
                       CASE WHEN %(vu)s THEN now() END)""",
            {"u": demande.id_utilisateur, "c": message, "e": echange["id_echange"],
             "vu": demande.deja_affichee})
    return reponse.depuis_echange(echange)


def garder_le_texte(demande: Demande, moment: str | None = None) -> int | None:
    """Opération C10, étape 1 : le texte de l'utilisateur est gardé avant tout appel."""
    if not (demande.texte or "").strip():
        return None
    ligne = executer(
        """INSERT INTO echange (id_utilisateur, auteur, moment, contenu, id_occurrence)
           VALUES (%(u)s, 'utilisateur', %(m)s, %(c)s, %(o)s) RETURNING id_echange""",
        {"u": demande.id_utilisateur, "m": moment or demande.moment,
         "c": demande.texte.strip(), "o": demande.id_occurrence})
    return ligne["id_echange"]


# ---------------------------------------------------------------------------
# La boucle
# ---------------------------------------------------------------------------

def appeler_coach(demande: Demande) -> dict:
    """Un appel complet. Rend la réponse dans sa forme fixe (section 9.3).

    Pour un appel à la demande, une réponse est toujours rendue : celle du
    coach, ou le message fixe si le modèle n'a pas répondu (COA-12). Pour un
    appel planifié, un échec lève EchecAppel, et l'ordonnanceur réessaie.
    """
    conf = configuration()
    planifie = demande.declencheur != "utilisateur"
    delai = float(conf.coach_delai_planifie_secondes if planifie
                  else conf.coach_delai_secondes)
    depart = time.monotonic()

    compte = un_seul("SELECT coach_actif, en_pause(id_utilisateur) AS en_pause "
                     "FROM utilisateur WHERE id_utilisateur = %(u)s AND actif",
                     {"u": demande.id_utilisateur})
    if compte is None or not compte["coach_actif"]:
        raise CoachInactif("Le coach n'est pas activé pour ce compte")

    deja = _deja_demande(demande, delai)
    if deja is not None:
        return deja

    # Le texte de l'utilisateur lui est rendu avec les derniers échanges des
    # appels suivants : il est donc lu avant d'être gardé, pour ne pas figurer
    # deux fois dans celui-ci.
    echanges = derniers_echanges(demande.id_utilisateur)
    id_texte = garder_le_texte(demande) if demande.essai == 1 else None

    operation_id = demande.operation_id or uuid.uuid4().hex[:16]
    id_appel = _ouvrir_appel(demande, operation_id, delai)
    if id_appel is None:
        if planifie:
            raise EchecAppel("Un autre appel est resté en cours", operation_id, demande.essai)
        return _enregistrer(demande, demande.moment, "systeme",
                            reponse.MESSAGE_INJOIGNABLE, [], None, None)

    suivi = {"tours": 0, "entree": 0, "cache": 0, "sortie": 0, "moment": demande.moment,
             "deroule": []}
    with operation.ouvrir_a_part(f"coach : {demande.moment}", "coach", operation_id):
        try:
            texte = _boucler(demande, compte, echanges, id_texte, suivi,
                             depart + delai)
            moment = suivi["moment"]
            elements = reponse.elements_de(operation_id)
            rendu = _enregistrer(demande, moment, "coach",
                                 texte.strip() or reponse.MESSAGE_SANS_TEXTE,
                                 elements, operation_id, id_appel)
            _clore_appel(id_appel, "termine", suivi)
            return rendu
        except Exception as erreur:  # noqa: BLE001 - tout échec clôt l'appel
            motif = f"{type(erreur).__name__} : {erreur}"[:500]
            LOG.warning("Appel au coach échoué (%s, essai %s) : %s",
                        demande.moment, demande.essai, motif)
            if not isinstance(erreur, (modele.ModeleInjoignable, _Arret)):
                LOG.exception("Erreur inattendue dans un appel au coach")
            _clore_appel(id_appel, "echoue", suivi, motif)
            if planifie:
                raise EchecAppel(motif, operation_id, demande.essai) from erreur
            # COA-12 : le message fixe, tout de suite. Ce qui a été écrit reste.
            return _enregistrer(demande, suivi["moment"], "systeme",
                                reponse.MESSAGE_INJOIGNABLE,
                                reponse.elements_de(operation_id), operation_id, id_appel)


class _Arret(Exception):
    """La boucle s'arrête d'elle-même : borne de tours ou délai dépassé (COA-7)."""


def _boucler(demande: Demande, compte: dict, echanges: str, id_texte: int | None,
             suivi: dict, limite: float) -> str:
    conf = configuration()
    id_utilisateur = demande.id_utilisateur
    moment = demande.moment
    # PAU-6 : à la reprise, la pause vient d'être levée et la révision a tout.
    en_pause = bool(compte["en_pause"]) and not demande.extra.get("reprise")
    permis = outils.outils_du_moment(moment, en_pause)
    borne = conf.coach_tours_plan if moment in MOMENTS_LONGS else conf.coach_tours

    deja_ecrit = reponse.elements_de(suivi_operation()) if demande.essai > 1 else []
    systeme = consigne(id_utilisateur)
    messages: list[dict] = [{"role": "user", "content": [
        {"type": "text", "text": echanges + "\n\n" + _moment_du(demande, deja_ecrit)}]}]
    requalifie = False

    while True:
        restant = limite - time.monotonic()
        if restant <= 1:
            raise _Arret("Délai dépassé")

        _marquer_le_cache(messages)
        tour = modele.appeler(systeme, messages, [o.declaration() for o in permis], restant)
        suivi["entree"] += tour.tokens_entree
        suivi["cache"] += tour.tokens_cache
        suivi["sortie"] += tour.tokens_sortie

        if not tour.outils:
            if tour.arret == "max_tokens" and not tour.texte.strip():
                raise _Arret("Réponse coupée avant d'être écrite")
            return tour.texte

        # COA-7 : au-delà de la borne, l'appel est arrêté et rien de plus n'est écrit.
        suivi["tours"] += 1
        if suivi["tours"] > borne:
            raise _Arret(f"Borne de {borne} tours d'outils dépassée")

        messages.append({"role": "assistant", "content": tour.brut})
        resultats = []
        noms_permis = {o.nom for o in permis}
        for voulu in tour.outils:
            if voulu.nom == "requalifier_en_signalement" and "requalifier_en_signalement" \
                    in noms_permis and not requalifie:
                # COA-25 : le texte du chat était un signalement. L'appel reprend
                # avec le moment signalement et ses outils, dans la même opération.
                requalifie = True
                moment = "signalement"
                suivi["moment"] = moment
                operation.preciser("coach : signalement")
                permis = outils.outils_du_moment(moment, en_pause)
                noms_permis = {o.nom for o in permis}
                executer("UPDATE appel_coach SET moment = 'signalement' "
                         "WHERE operation = %(o)s AND statut = 'en_cours'",
                         {"o": suivi_operation()})
                if id_texte is not None:
                    executer("UPDATE echange SET moment = 'signalement' "
                             "WHERE id_echange = %(e)s", {"e": id_texte})
                contenu, erreur = (
                    "Requalifié en signalement. Tu disposes maintenant des outils du "
                    "signalement : applique d'abord le chapitre 1.2, puis le chapitre 8.4 "
                    "ou 7.4 selon le cas. Tu peux retirer ou modifier des séances "
                    "proposées, et déposer un ajustement sur une séance validée. Note au "
                    "carnet ce qui doit être retenu.", False)
            else:
                contenu, erreur = outils.executer_outil(
                    voulu.nom, id_utilisateur, voulu.arguments, noms_permis)
            suivi["deroule"].append({"tour": suivi["tours"], "outil": voulu.nom,
                                     "arguments": voulu.arguments, "refus": bool(erreur),
                                     "resultat": contenu[:400]})
            bloc = {"type": "tool_result", "tool_use_id": voulu.identifiant,
                    "content": contenu}
            if erreur:
                bloc["is_error"] = True
            resultats.append(bloc)
        messages.append({"role": "user", "content": resultats})


def suivi_operation() -> str:
    en_cours = operation.courante()
    return en_cours.identifiant if en_cours else ""


def _marquer_le_cache(messages: list[dict]) -> None:
    """Un seul repère de cache dans la conversation, sur son dernier bloc.

    D'un tour à l'autre, tout ce qui précède a déjà été lu : le fournisseur le
    relit depuis son cache au lieu de le refacturer plein tarif.
    """
    for message in messages:
        if isinstance(message.get("content"), list):
            for bloc in message["content"]:
                if isinstance(bloc, dict):
                    bloc.pop("cache_control", None)
    dernier = messages[-1]["content"]
    if isinstance(dernier, list) and dernier and isinstance(dernier[-1], dict):
        dernier[-1]["cache_control"] = {"type": "ephemeral"}


def liberer_les_appels_bloques() -> int:
    """COA-22 : au démarrage, un appel resté en cours passe à échoué."""
    minutes = max(configuration().coach_delai_planifie_secondes // 60 + 1, 2)
    ligne = executer("SELECT liberer_appels_bloques(%(m)s) AS n", {"m": minutes})
    return (ligne or {}).get("n", 0)
