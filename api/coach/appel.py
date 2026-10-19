"""Un appel au coach, du déclencheur à la réponse            (opération C1)

Le modèle ne retient rien d'un appel à l'autre et ne peut rien faire seul. Le
module lui envoie une consigne et la liste des outils permis pour ce moment,
exécute les outils qu'il demande, et recommence jusqu'à ce qu'il rende un
texte. Il ne décide de rien : il transmet.

    1. un seul appel en cours par compte, l'appel est enregistré      (COA-21, COA-22)
    2. une opération du journal à lui, sous l'acteur « coach »        (COA-6)
    3. la consigne : socle, paquets du sujet, contexte et mémoire,
       derniers échanges, moment                       (COA-3, DOS-3, MEM-1)
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
from api.coach import (
    aiguillage,
    contexte,
    course,
    dossier,
    fournisseurs,
    modele,
    office,
    outils,
    reponse,
    trace,
)
from api.coach.clair import clair, jour_en_clair, maintenant
from api.config import configuration

LOG = logging.getLogger(__name__)

# Les moments qui construisent beaucoup : trente tours au lieu de douze (COA-7).
MOMENTS_LONGS = ("plan", "revision")

# MEM-10 : la longueur gardée d'un ancien message du coach dans les derniers échanges.
LONGUEUR_ANCIEN_MESSAGE = 500


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
    # COA-33 : ce que l'appli affiche quand le message part, en clair.
    ecran: str | None = None


def _moment_du(demande: Demande, deja_ecrit: list[dict], relais: bool = False) -> str:
    """Le message du moment : ce qui déclenche l'appel, et ce qu'on attend."""
    m = demande.moment
    jour = maintenant()
    lignes = [f"# Moment : {m}",
              f"{jour_en_clair(jour.date())} {jour.year}, {jour:%H:%M}."]

    if m == "faisabilite":
        lignes.append(
            "Un objectif vient d'être créé ou modifié. Les séances récentes, les mesures et "
            "l'emploi du temps sont joints plus haut. Juge sur la meilleure séance, pas "
            "seulement la dernière, et pas sur un footing pour un chrono. Rends ton avis "
            "avec `rendre_avis` : réaliste, ambitieux ou irréaliste. Ton message est court : ton "
            "avis en deux ou trois phrases, les deux ou trois chiffres qui le fondent, et ce "
            "qui va suivre. L'objectif reste celui de l'utilisateur : tu ne le remplaces pas. "
            "S'il manque le temps visé pour une course, demande-le lui. Si les objectifs se "
            "contredisent, dis lequel tu mettrais en pause : tu ne le fais jamais toi-même.")
    elif m == "plan":
        lignes.append(
            "Construis le plan de quatre semaines à partir de l'objectif principal. Dans "
            "l'ordre : écris ou révise la feuille de route, crée le plan avec `ecrire_trame` "
            "(nouveau_plan à vrai), puis propose toutes les séances avec `proposer_seances`, "
            "en un seul appel si tu peux. L'emploi du temps, la santé, la forme et le "
            "catalogue sont joints plus haut. La première semaine est détaillée, "
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
            "validation. Si le plan est arrivé à son terme, construis le suivant dans ce "
            "même appel. Termine en réécrivant la mémoire de la semaine : cette nuit, elle "
            "sera versée dans celle du mois.")
    elif m == "synthese":
        lignes.append(
            "C'est la synthèse du soir. Elle couvre la journée entière : séances faites, pas "
            "faites ou non validées, données de santé et leur fraîcheur, mesures attendues, "
            "déplacements faits par l'utilisateur, objectifs échus, séances faites sans "
            "bilan. Pour chaque séance pas faite, décide : une séance clé est proposée à "
            "nouveau s'il reste un jour qui tient, une séance secondaire est abandonnée. "
            "Pour chaque séance libre du jour, rends un avis puis compense ou allège la "
            "suite. Ajoute à la mémoire de la semaine ce que la journée a appris, s'il y a "
            "quelque chose (`ajouter_memoire`). Termine par "
            "ce qui attend demain. Un jour sans rien à dire donne une synthèse courte, pas "
            "un silence.")
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
            "déposes un ajustement. Si l'utilisateur veut faire autre chose à la place "
            "(un footing au lieu de la musculation), retirer ne suffit pas : propose "
            "aussi la séance qui remplace, avec `proposer_seance`, dans le même appel. "
            "Ne laisse jamais un trou là où il a dit ce qu'il ferait. Garde la trace de "
            "ce qui est signalé dans la mémoire de la semaine, et marque l'échange "
            "important s'il change la suite.")
    elif m == "changement":
        lignes.append(
            "L'utilisateur a touché « Demander un changement » dans l'appli, sur l'élément "
            "joint plus bas, et t'explique ce qu'il veut. Tu proposes, il valide d'un "
            "bouton : rien ne change sans lui. Sur une séance proposée, modifie-la ou "
            "retire-la et propose la nouvelle version ; elle reste à valider. Sur une "
            "séance validée, tu ne la modifies pas : tu déposes un ajustement "
            "(`proposer_ajustement`) avec son motif, qu'il acceptera ou non. S'il veut "
            "faire autre chose à la place, propose aussi la séance qui remplace "
            "(`proposer_seance`) : un retrait seul laisse un trou. Si sa demande "
            "n'est pas claire, pose une seule question, avec deux ou trois réponses "
            "possibles. Ton message dit en une ou deux phrases ce que tu proposes et "
            "pourquoi ; les boutons pour valider s'affichent dessous.")
    elif m == "chat":
        lignes.append(
            "L'utilisateur t'écrit. Une question : réponds-y. Tu n'as pas ici les outils "
            "de séance. Appelle d'abord `requalifier_en_signalement` si son texte demande "
            "un changement du plan (ajouter, déplacer, retirer ou changer une séance, "
            "courir un autre jour), s'il signale une douleur, une fatigue ou un "
            "contretemps, ou s'il répond à une question que tu as posée : tu auras alors "
            "les outils pour agir. Une mesure qu'il te donne (poids, tour de bras, temps) "
            "s'enregistre avec `noter_mesure`. N'écris jamais « c'est noté », « je vais "
            "proposer » ou « je déplace » sans l'avoir fait par un outil dans cet appel.")

    if demande.precision:
        lignes.append(demande.precision)
    if demande.ecran:
        # COA-33 : une information, pas une permission.
        lignes.append(f"L'appli affiche : {demande.ecran}. C'est ce que l'utilisateur a sous "
                      "les yeux : tu n'agis qu'avec les outils de ce moment.")
    if demande.id_occurrence:
        lignes.append(f"La séance dont on parle : id_occurrence {demande.id_occurrence}.")
    if deja_ecrit and relais and demande.essai == 1:
        # FOU-4 : un fournisseur a cédé en route ; le suivant termine.
        lignes.append(
            "ATTENTION : cet appel a commencé avec un autre fournisseur, qui s'est "
            "interrompu, mais ce qu'il a écrit est resté. Ne le refais pas : vérifie avec "
            "tes outils de lecture, termine ce qui manque, puis rédige ton message. Déjà "
            "écrit par cette opération : " + _resume(deja_ecrit))
    elif deja_ecrit:
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
        """SELECT quand, auteur, moment, contenu, client FROM (
               SELECT e.id_echange, e.quand, e.auteur, e.moment, e.contenu, e.client
                 FROM echange e WHERE e.id_utilisateur = %(u)s
                ORDER BY e.id_echange DESC LIMIT %(n)s) x
            ORDER BY id_echange""",
        {"u": id_utilisateur, "n": configuration().coach_echanges_rendus})
    if not lignes:
        return "# Derniers échanges\n\nAucun échange pour l'instant : c'est le premier."
    morceaux = ["# Derniers échanges (du plus ancien au plus récent)"]
    # MEM-10 : tes anciens messages sont raccourcis, le dernier reste entier. Ce
    # qu'ils annonçaient est en base, et relu à jour ; ce que l'utilisateur a
    # écrit reste toujours mot pour mot.
    dernier_du_coach = max((i for i, x in enumerate(lignes) if x["auteur"] == "coach"),
                           default=None)
    for rang, ligne in enumerate(lignes):
        # MCP-12 : un résumé déposé par un client MCP dit de quel client il vient.
        qui = {"utilisateur": "Utilisateur", "coach": "Toi",
               "systeme": "Message automatique",
               "client": f"Résumé d'une conversation dans {ligne['client']}"}[ligne["auteur"]]
        contenu = ligne["contenu"]
        if ligne["auteur"] != "utilisateur" and rang != dernier_du_coach \
                and len(contenu) > LONGUEUR_ANCIEN_MESSAGE:
            contenu = contenu[:LONGUEUR_ANCIEN_MESSAGE].rstrip() + " […]"
        morceaux.append(f"[{clair(ligne['quand'])}, {ligne['moment']}] {qui} : {contenu}")
    return "\n\n".join(morceaux)


def consigne(id_utilisateur: int, choix: dict[str, str] | None = None) -> list[dict]:
    """La consigne, du plus stable au plus changeant.

    Le fournisseur facture moins cher une partie déjà vue : la partie fixe vient
    donc en premier et reste identique d'un appel à l'autre, au caractère près.
    Puis les paquets du dossier choisis pour cet appel (DOS-3), identiques pour
    un même choix. Puis le contexte et la mémoire.
    """
    return [
        {"type": "text", "text": dossier.consigne() + "\n\n" + dossier.base(),
         "cache_control": {"type": "ephemeral"}},
        {"type": "text", "text": dossier.texte_des_paquets(choix or {}),
         "cache_control": {"type": "ephemeral"}},
        {"type": "text", "text": contexte.texte(id_utilisateur),
         "cache_control": {"type": "ephemeral"}},
    ]


def appel_en_cours(id_utilisateur: int) -> str | None:
    """Le moment de l'appel en cours pour ce compte, s'il y en a un (COA-22)."""
    ligne = un_seul("SELECT moment FROM appel_coach WHERE id_utilisateur = %(u)s "
                    "AND statut = 'en_cours' LIMIT 1", {"u": id_utilisateur})
    return (ligne or {}).get("moment")


def dernier_message_du_coach(id_utilisateur: int) -> str | None:
    ligne = un_seul("SELECT contenu FROM echange WHERE id_utilisateur = %(u)s "
                    "AND auteur = 'coach' ORDER BY id_echange DESC LIMIT 1",
                    {"u": id_utilisateur})
    return (ligne or {}).get("contenu")


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
                 "c": demande.cle_client, "mo": modele_de(demande)})
            return ligne["id_appel"]
        except psycopg.errors.UniqueViolation:
            if time.monotonic() >= limite:
                return None
            time.sleep(1.0)


def _clore_appel(id_appel: int, statut: str, compte: dict, motif: str | None = None) -> None:
    executer(
        """UPDATE appel_coach
              SET statut = %(s)s, fin = now(), tours = %(t)s, tokens_entree = %(e)s,
                  tokens_cache = %(c)s, tokens_cache_ecrit = %(ce)s,
                  tokens_sortie = %(so)s, motif_echec = %(m)s,
                  moment = %(mo)s, deroule = %(d)s, fournisseur = %(f)s
            WHERE id_appel = %(a)s""",
        {"s": statut, "a": id_appel, "t": compte["tours"], "e": compte["entree"],
         "c": compte["cache"], "ce": compte.get("cache_ecrit", 0), "so": compte["sortie"],
         "m": motif, "mo": compte["moment"],
         "d": Jsonb(compte["deroule"]), "f": compte.get("fournisseur")})


def _enregistrer(demande: Demande, moment: str, auteur: str, message: str,
                 elements: list[dict], operation_id: str | None,
                 id_appel: int | None, fournisseur: str | None = None) -> dict:
    """L'échange et sa notification, dans une même transaction (COA-16, NOT-2).

    Écrits avant que la réponse soit rendue : une réponse perdue en route se
    relit dans les échanges et arrive aussi par le bot.
    """
    with connexion() as conn, conn.cursor() as cur:
        cur.execute(
            """INSERT INTO echange (id_utilisateur, auteur, moment, contenu, id_occurrence,
                                    operation, modele, version_dossier, elements, id_appel,
                                    fournisseur)
               VALUES (%(u)s, %(a)s, %(m)s, %(c)s, %(o)s, %(op)s, %(mo)s, %(v)s, %(e)s, %(ap)s,
                       %(f)s)
               RETURNING id_echange, moment, auteur, contenu, elements, quand""",
            {"u": demande.id_utilisateur, "a": auteur, "m": moment, "c": message,
             "o": demande.id_occurrence, "op": operation_id,
             "mo": modele_de(demande) if auteur == "coach" else None,
             "v": dossier.version() if auteur == "coach" else None,
             "e": Jsonb(elements), "ap": id_appel,
             "f": fournisseur if auteur == "coach" else None})
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

# COA-31 : les familles d'outils retirées à une synthèse de jour sans séance.
FERMEES_SI_SIMPLE = {"seances", "fenetre", "avis_libre", "trame"}


def modele_de(demande: Demande) -> str:
    """Le modèle de cet appel : le moins cher pour le chat et la synthèse simple,
    s'il est réglé (COA-31)."""
    conf = configuration()
    simple = demande.moment == "chat" or demande.extra.get("simple")
    return (conf.coach_modele_simple if simple else "") or conf.coach_modele


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
    # DOS-2 : les paquets du dossier, choisis avant que le texte soit gardé, pour
    # que « le dernier message du coach » soit bien celui auquel il répond.
    if demande.extra.get("simple"):
        # COA-31 : un jour sans séance, le socle suffit.
        choix = aiguillage.Aiguillage()
    else:
        choix = aiguillage.choisir(demande.id_utilisateur, demande.moment, demande.texte,
                                   demande.id_occurrence,
                                   dernier_message_du_coach(demande.id_utilisateur)
                                   if demande.texte else None)
    id_texte = garder_le_texte(demande) if demande.essai == 1 else None

    operation_id = demande.operation_id or uuid.uuid4().hex[:16]
    # Un message écrit pendant qu'un plan se construit attend la fin du plan, qui
    # peut prendre plusieurs minutes, puis a tout son délai à lui.
    attente = delai if planifie else max(delai, float(conf.coach_delai_planifie_secondes))
    id_appel = _ouvrir_appel(demande, operation_id, attente)
    depart = time.monotonic()
    if id_appel is None:
        if planifie:
            raise EchecAppel("Un autre appel est resté en cours", operation_id, demande.essai)
        return _enregistrer(demande, demande.moment, "systeme",
                            reponse.MESSAGE_INJOIGNABLE, [], None, None)

    # MEM-8 : le texte de l'utilisateur est rattaché à l'appel qui y répond, et en
    # prend l'importance.
    executer("UPDATE appel_coach SET paquets = %(p)s WHERE id_appel = %(a)s",
             {"p": choix.en_liste(), "a": id_appel})
    if id_texte is not None:
        executer("UPDATE echange SET id_appel = %(a)s WHERE id_echange = %(e)s",
                 {"a": id_appel, "e": id_texte})

    suivi = {"tours": 0, "entree": 0, "cache": 0, "cache_ecrit": 0, "sortie": 0,
             "moment": demande.moment,
             "deroule": [{"aiguillage": choix.en_liste(), "par": choix.par or "moment",
                          "tokens_entree": choix.tokens_entree,
                          "tokens_sortie": choix.tokens_sortie}],
             "choix": choix.choix}
    with operation.ouvrir_a_part(f"coach : {demande.moment}", "coach", operation_id):
        try:
            texte = _par_les_fournisseurs(demande, compte, echanges, id_texte, suivi,
                                          depart + delai)
            moment = suivi["moment"]
            elements = reponse.elements_de(operation_id)
            rendu = _enregistrer(demande, moment, "coach",
                                 texte.strip() or reponse.MESSAGE_SANS_TEXTE,
                                 elements, operation_id, id_appel, suivi.get("fournisseur"))
            _clore_appel(id_appel, "termine", suivi)
            trace.ecrire(id_appel, moment, suivi, texte)
            # FOU-9 : la réponse dit par qui elle est venue, quand ce n'est pas le premier.
            rendu["fournisseur"] = _fournisseur_en_clair(suivi)
            return rendu
        except Exception as erreur:  # noqa: BLE001 - tout échec clôt l'appel
            motif = f"{type(erreur).__name__} : {erreur}"[:500]
            LOG.warning("Appel au coach échoué (%s, essai %s) : %s",
                        demande.moment, demande.essai, motif)
            if not isinstance(erreur, (modele.ModeleInjoignable, _Arret)):
                LOG.exception("Erreur inattendue dans un appel au coach")
            _clore_appel(id_appel, "echoue", suivi, motif)
            trace.ecrire(id_appel, suivi["moment"], suivi, None, motif)
            if planifie:
                raise EchecAppel(motif, operation_id, demande.essai) from erreur
            # COA-12 : le message fixe, tout de suite. Ce qui a été écrit reste.
            # FOU-8 : quand tout est de côté, il dit jusqu'à quand.
            return _enregistrer(demande, suivi["moment"], "systeme",
                                reponse.MESSAGE_INJOIGNABLE
                                + _retour_des_fournisseurs(demande.id_utilisateur),
                                reponse.elements_de(operation_id), operation_id, id_appel)


_Arret = fournisseurs.Arret


# ---------------------------------------------------------------------------
# La chaîne des fournisseurs (FOU-4)
# ---------------------------------------------------------------------------

def _par_les_fournisseurs(demande: Demande, compte: dict, echanges: str,
                          id_texte: int | None, suivi: dict, limite: float) -> str:
    """L'appel passe par le premier fournisseur disponible du compte. S'il cède,
    le suivant termine dans la même opération, en sachant ce qui est déjà écrit."""
    chaine = fournisseurs.chaine(demande.id_utilisateur)
    if not chaine:
        raise modele.ModeleInjoignable("Aucun fournisseur disponible : tous sont de côté")
    for rang, fournisseur in enumerate(chaine):
        suivi["fournisseur"] = fournisseur.colonne
        try:
            if fournisseur.type == "claude_code":
                texte = _par_claude_code(demande, compte, echanges, id_texte, suivi, limite,
                                         fournisseur.secret)
            else:
                try:
                    texte = _boucler(demande, compte, echanges, id_texte, suivi, limite,
                                     fournisseur.secret)
                except modele.ModeleInjoignable as erreur:
                    # Le dernier de la chaîne échoue comme avant (COA-12).
                    if rang == len(chaine) - 1:
                        raise
                    raise fournisseurs.Indisponible(erreur.nature, str(erreur)) from erreur
            fournisseurs.a_servi(fournisseur)
            return texte
        except fournisseurs.Indisponible as erreur:
            LOG.warning("%s cède (%s) : %s", fournisseur.libelle, erreur.nature, erreur.motif)
            fournisseurs.ceder(fournisseur, erreur)
            suivi["deroule"].append({"fournisseur": fournisseur.type, "cede": erreur.nature,
                                     "motif": erreur.motif[:200],
                                     "jusqu_a": clair(erreur.jusqu_a)})
            suivi["relais"] = True
            if time.monotonic() >= limite - 1:
                raise _Arret("Délai dépassé") from erreur
    raise modele.ModeleInjoignable("Tous les fournisseurs ont cédé")


def _fournisseur_en_clair(suivi: dict) -> dict:
    """FOU-9 : le fournisseur qui a répondu, et pourquoi pas le premier."""
    type_ = suivi.get("fournisseur") or "serveur"
    cedes = [x for x in suivi["deroule"] if "cede" in x]
    rendu = {"type": type_, "libelle": fournisseurs.LIBELLES.get(type_, type_)}
    if cedes:
        dernier = cedes[-1]
        raison = {"limite": "épuisé", "jeton": "à reconnecter", "plafond": "plafond atteint",
                  "injoignable": "injoignable"}.get(dernier["cede"], dernier["cede"])
        jusqu = f" jusqu'à {dernier['jusqu_a'][11:16]}" if dernier.get("jusqu_a") else ""
        rendu["note"] = (f"Par {fournisseurs.COURTS.get(type_, type_)} : "
                         f"{fournisseurs.COURTS.get(dernier['fournisseur'], '')} "
                         f"{raison}{jusqu}")
    return rendu


def _retour_des_fournisseurs(id_utilisateur: int) -> str:
    """FOU-8 : quand reviendra le premier fournisseur mis de côté, s'il y en a un."""
    ligne = un_seul(
        """SELECT min(de_cote_jusqu_a) AS retour FROM fournisseur_modele
            WHERE id_utilisateur = %(u)s AND etat = 'de_cote'""", {"u": id_utilisateur})
    retour = (ligne or {}).get("retour")
    if not retour:
        return ""
    return f" Ton abonnement et l'API sont de côté jusqu'au {clair(retour)}."


@dataclass
class _Preparation:
    permis: list
    borne: int
    modele_nom: str
    systeme: list[dict]
    premier: str
    en_pause: bool


def _preparer(demande: Demande, compte: dict, echanges: str, suivi: dict) -> _Preparation:
    """Ce que le modèle reçoit, quel que soit le fournisseur : outils, consigne,
    premier message (B.2.3)."""
    conf = configuration()
    id_utilisateur = demande.id_utilisateur
    moment = suivi["moment"]
    # PAU-6 : à la reprise, la pause vient d'être levée et la révision a tout.
    en_pause = bool(compte["en_pause"]) and not demande.extra.get("reprise")
    permis = outils.outils_du_moment(moment, en_pause)
    if demande.extra.get("simple"):
        permis = [o for o in permis if o.famille not in FERMEES_SI_SIMPLE]
    borne = conf.coach_tours_plan if moment in MOMENTS_LONGS else conf.coach_tours
    relais = bool(suivi.get("relais"))
    deja_ecrit = reponse.elements_de(suivi_operation()) \
        if demande.essai > 1 or relais else []
    systeme = consigne(id_utilisateur, suivi.get("choix"))
    # COA-28 : ce que le moment lit à coup sûr est joint d'office, pour épargner
    # un passage entier au modèle.
    lu = office.texte(id_utilisateur, moment, demande.id_occurrence)
    premier = "\n\n".join(x for x in (echanges, lu, _moment_du(demande, deja_ecrit, relais))
                           if x)
    return _Preparation(permis, borne, modele_de(demande), systeme, premier, en_pause)


def _requalifier(suivi: dict, id_texte: int | None) -> None:
    """COA-25 : le texte du chat était un signalement. L'appel reprend avec ce
    moment et ses outils, dans la même opération."""
    suivi["moment"] = "signalement"
    operation.preciser("coach : signalement")
    executer("UPDATE appel_coach SET moment = 'signalement' "
             "WHERE operation = %(o)s AND statut = 'en_cours'",
             {"o": suivi_operation()})
    if id_texte is not None:
        executer("UPDATE echange SET moment = 'signalement' "
                 "WHERE id_echange = %(e)s", {"e": id_texte})


def _par_claude_code(demande: Demande, compte: dict, echanges: str, id_texte: int | None,
                     suivi: dict, limite: float, jeton_abonnement: str) -> str:
    """FOU-10 : la même consigne et le même premier message que l'API, mais c'est
    Claude Code qui fait la boucle, sur l'abonnement du compte."""
    id_utilisateur = demande.id_utilisateur
    prep = _preparer(demande, compte, echanges, suivi)
    systeme = "\n\n".join(bloc["text"] for bloc in prep.systeme)
    suivi["systeme"] = prep.systeme
    suivi["messages"] = [{"role": "user", "content": [{"type": "text", "text": prep.premier}]}]
    premier = prep.premier
    operation_id = suivi_operation()

    for _ in range(2):
        moment = suivi["moment"]
        operation_courante = operation.courante()

        def sur_requalification(op=operation_courante) -> None:
            # Appelé depuis le serveur MCP, dans un autre fil : l'opération y est
            # remise pour que le journal reste celui de l'appel.
            with operation.ouvrir_a_part(op.origine, op.acteur or "coach", op.identifiant):
                _requalifier(suivi, id_texte)

        etat = course.EtatCourse(
            id_utilisateur=id_utilisateur, moment=moment, operation=operation_id,
            permis=prep.permis, borne=prep.borne, deroule=suivi["deroule"],
            sur_requalification=sur_requalification
            if "requalifier_en_signalement" in {o.nom for o in prep.permis} else None)
        etat.tours = suivi["tours"]

        def relecture(texte: str, moment=moment, etat=etat) -> str | None:
            # COA-30 : un plan posé ou changé se relit une fois contre la base.
            a_pose = any(e.get("outil") in OUTILS_DE_SEANCE and not e.get("refus")
                         for e in suivi["deroule"])
            if etat.requalifiee or moment not in MOMENTS_LONGS or not a_pose:
                return None
            releve = controle_du_plan(id_utilisateur)
            if not releve:
                return None
            suivi["deroule"].append({"controle": releve[:400]})
            return _consigne_de_relecture(releve)

        passage = course.courir(etat, systeme, premier, prep.modele_nom, jeton_abonnement,
                                limite, relecture)
        suivi["tours"] = etat.tours
        suivi["entree"] += passage.entree
        suivi["cache"] += passage.cache
        suivi["cache_ecrit"] += passage.cache_ecrit
        suivi["sortie"] += passage.sortie
        suivi["deroule"].append({"claude_code": True, "tours_modele": passage.tours_modele,
                                 "entree": passage.entree, "cache_lu": passage.cache,
                                 "cache_ecrit": passage.cache_ecrit,
                                 "sortie": passage.sortie})
        if not etat.requalifiee:
            return passage.texte
        # FOU-13 : la course s'est arrêtée sur la requalification ; la suivante a
        # les outils du signalement, et le même texte à traiter.
        prep = _preparer(demande, compte, echanges, suivi)
        premier = prep.premier + "\n\n" + REQUALIFIE_POUR_LA_SUITE
    return passage.texte


REQUALIFIE_POUR_LA_SUITE = (
    "Ce message a été requalifié en signalement. Tu disposes maintenant des outils du "
    "signalement : applique d'abord le chapitre 1.2, puis le chapitre 8.4 ou 7.4 selon le "
    "cas. Tu peux retirer ou modifier des séances proposées, et déposer un ajustement sur "
    "une séance validée. Garde la trace de ce qui est signalé dans la mémoire de la "
    "semaine.")


def _consigne_de_relecture(releve: str) -> str:
    return ("Relecture avant envoi. Voici ce qui est réellement posé en base :\n"
            + releve + "\nCompare avec ton message : chaque séance qu'il annonce "
            "(jour, type, distance ou durée) doit y être. Si tout correspond, réponds "
            "seulement OK. Sinon, pose ou corrige avec tes outils, puis réécris ton "
            "message final en entier.")


# ---------------------------------------------------------------------------
# La boucle de l'API
# ---------------------------------------------------------------------------

def _boucler(demande: Demande, compte: dict, echanges: str, id_texte: int | None,
             suivi: dict, limite: float, cle: str | None = None) -> str:
    id_utilisateur = demande.id_utilisateur
    prep = _preparer(demande, compte, echanges, suivi)
    moment = suivi["moment"]
    permis, borne, modele_nom, systeme = prep.permis, prep.borne, prep.modele_nom, prep.systeme
    en_pause = prep.en_pause
    messages: list[dict] = [{"role": "user", "content": [
        {"type": "text", "text": prep.premier}]}]
    # Pour la trace : ce que le modèle lit, tel qu'il le lit (COACH_TRACE_DOSSIER).
    suivi["systeme"], suivi["messages"] = systeme, messages
    requalifie = False
    # FOU-1 : la clé du compte, si elle est donnée ; sinon celle du serveur.
    avec_cle = {"cle": cle} if cle else {}

    while True:
        restant = limite - time.monotonic()
        if restant <= 1:
            raise _Arret("Délai dépassé")

        _marquer_le_cache(messages)
        tour = modele.appeler(systeme, messages,
                             [o.declaration() for o in permis if not o.cache], restant,
                             modele_nom, **avec_cle)
        suivi["entree"] += tour.tokens_entree
        suivi["cache"] += tour.tokens_cache
        suivi["cache_ecrit"] += tour.tokens_cache_ecrit
        suivi["sortie"] += tour.tokens_sortie
        # Ce que chaque passage au modèle a coûté : pour voir où part l'argent.
        suivi["deroule"].append({
            "jetons": suivi["tours"], "neufs": tour.tokens_entree - tour.tokens_cache
            - tour.tokens_cache_ecrit, "cache_ecrit": tour.tokens_cache_ecrit,
            "cache_lu": tour.tokens_cache, "sortie": tour.tokens_sortie,
            "arret": tour.arret})

        if not tour.outils:
            if tour.arret == "max_tokens" and not tour.texte.strip():
                raise _Arret("Réponse coupée avant d'être écrite")
            # COA-30 : quand l'appel a posé ou changé des séances d'un plan, le
            # message est relu une fois contre ce qui est vraiment en base.
            if suivi.get("controle") is not None:
                if tour.texte.strip().strip(".").upper() == "OK":
                    return suivi["controle"]
                return tour.texte
            a_pose = any(e.get("outil") in OUTILS_DE_SEANCE and not e.get("refus")
                         for e in suivi["deroule"])
            releve = controle_du_plan(id_utilisateur) \
                if moment in MOMENTS_LONGS and a_pose else None
            if not releve:
                return tour.texte
            suivi["controle"] = tour.texte
            suivi["deroule"].append({"controle": releve[:400]})
            messages.append({"role": "assistant", "content": tour.brut})
            messages.append({"role": "user", "content": [
                {"type": "text", "text": _consigne_de_relecture(releve)}]})
            continue

        # COA-7 : au-delà de la borne, l'appel est arrêté et rien de plus n'est écrit.
        suivi["tours"] += 1
        if suivi["tours"] > borne:
            raise _Arret(f"Borne de {borne} tours d'outils dépassée")

        messages.append({"role": "assistant", "content": tour.brut})
        resultats = []
        noms_permis = {o.nom for o in permis}
        # COA-27 : une réponse coupée par la limite de sortie a son dernier appel
        # d'outil tronqué. Il n'est pas exécuté : le modèle le renvoie en entier.
        coupe = tour.outils[-1].identifiant if tour.arret == "max_tokens" else None
        for voulu in tour.outils:
            if voulu.identifiant == coupe:
                contenu, erreur = _refus_coupe(voulu.nom), True
            elif voulu.nom == "requalifier_en_signalement" and "requalifier_en_signalement" \
                    in noms_permis and not requalifie:
                # COA-25 : le texte du chat était un signalement. L'appel reprend
                # avec le moment signalement et ses outils, dans la même opération.
                requalifie = True
                _requalifier(suivi, id_texte)
                moment = suivi["moment"]
                permis = outils.outils_du_moment(moment, en_pause)
                noms_permis = {o.nom for o in permis}
                contenu, erreur = (
                    "Requalifié en signalement. Tu disposes maintenant des outils du "
                    "signalement : applique d'abord le chapitre 1.2, puis le chapitre 8.4 "
                    "ou 7.4 selon le cas. Tu peux retirer ou modifier des séances "
                    "proposées, et déposer un ajustement sur une séance validée. Garde la "
                    "trace de ce qui est signalé dans la mémoire de la semaine.", False)
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


def _refus_coupe(nom: str) -> str:
    import json
    return json.dumps({
        "refus": "demande_coupee",
        "motif": f"Ta demande « {nom} » a été coupée par la limite de longueur de ta "
                 "réponse : elle n'a pas été exécutée. Renvoie-la en entier, seule ou "
                 "avec moins d'éléments à la fois."}, ensure_ascii=False)


OUTILS_DE_SEANCE = {"proposer_seance", "proposer_seances", "modifier_seance_proposee",
                    "retirer_seance_proposee"}


def controle_du_plan(id_utilisateur: int) -> str | None:
    """COA-30 : les séances non validées du plan en cours, semaine par semaine, et
    les semaines sans séance clé. None s'il n'y a pas de plan."""
    seances = lister(
        """SELECT ps.lundi, ps.role, s.jour, s.discipline, s.type_seance, s.duree_minutes,
                  s.cle, s.situation, s.consigne
             FROM plan p JOIN plan_semaine ps ON ps.id_plan = p.id_plan
             LEFT JOIN v_seance_coach s ON s.id_utilisateur = p.id_utilisateur
                                       AND s.lundi = ps.lundi
                                       AND s.situation NOT IN ('retiree', 'remplacee')
            WHERE p.id_utilisateur = %(u)s AND p.statut = 'en_cours'
              AND ps.validee_le IS NULL AND ps.lundi + 6 >= jour_de(now())
            ORDER BY ps.lundi, s.jour, s.debut NULLS LAST""", {"u": id_utilisateur})
    if not seances:
        return None
    lignes, semaine, cles = [], None, 0

    def fin_de_semaine():
        if semaine and cles == 0 and semaine[1] not in ("allegee", "affutage"):
            lignes.append("  ATTENTION : aucune séance clé cette semaine.")

    for s in seances:
        if semaine != (s["lundi"], s["role"]):
            fin_de_semaine()
            semaine, cles = (s["lundi"], s["role"]), 0
            lignes.append(f"Semaine du {jour_en_clair(s['lundi'])} ({s['role']}) :")
        if s["jour"] is None:
            lignes.append("  aucune séance.")
            continue
        cles += 1 if s["cle"] else 0
        detail = f" ({s['consigne'][:80]})" if s.get("consigne") else ""
        lignes.append(f"  {jour_en_clair(s['jour'])} : {s['discipline'] or 'sport'}, "
                      f"{s['type_seance'] or 'séance'}, {s['duree_minutes'] or '?'} min"
                      f"{', clé' if s['cle'] else ''}{detail}")
    fin_de_semaine()
    return "\n".join(lignes)


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
