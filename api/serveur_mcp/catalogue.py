"""Les outils du profil externe                       (MCP-4, MCP-5, F.8.2)

Un client MCP de l'utilisateur lit tout ce qui est à lui : son planning, la
maison, ses séances, sa santé, sa mémoire. Les outils de lecture du coach sont
repris tels quels, sous leur nom ; ceux du planning et de la maison s'y
ajoutent. Il écrit ce que HAL écrit déjà seul (sa mémoire, une mesure dite), et
le résumé d'une conversation (MCP-12). Rien d'autre : ce qui change le planning
passera par une demande, que l'utilisateur accepte dans l'appli (ACC, lot 14).

Comme pour le coach, chaque outil travaille pour le titulaire de la clé et lui
seul : aucun ne prend un identifiant d'utilisateur (MCP-3). De l'autre membre
du foyer, un client ne lit que ce que l'appli lui montre déjà, sans le lieu de
ses absences (MCP-11).
"""

from datetime import timedelta
from functools import lru_cache

from api import demandes
from api.base import executer, lister, un_seul
from api.coach import contexte, dossier, memoire
from api.coach.clair import aujourd_hui, sans_vides
from api.coach.outils import PAR_NOM as OUTILS_DU_COACH
from api.coach.outils import Outil, RefusOutil, _jour, _objet

# Longueur d'un résumé de conversation : la base refuse au-delà.
RESUME_MAX = 2000


@lru_cache
def consigne() -> str:
    """MCP-6 : la consigne courte rendue à la connexion, `coach/consigne_mcp.md`."""
    fichier = dossier.racine().parent / "consigne_mcp.md"
    return fichier.read_text(encoding="utf-8").strip() if fichier.exists() else ""


def _membres(u: int) -> list[dict]:
    return lister(
        """SELECT id_utilisateur, pseudo, id_utilisateur = %(u)s AS moi
             FROM utilisateur
            WHERE id_foyer = foyer_de(%(u)s) AND actif
            ORDER BY id_utilisateur <> %(u)s, id_utilisateur""",
        {"u": u}) or [{"id_utilisateur": u, "pseudo": "moi", "moi": True}]


def _periode(a: dict, avant: int, apres: int, maximum: int) -> tuple:
    debut = _jour(a["du"], "du") if a.get("du") else aujourd_hui() - timedelta(days=avant)
    fin = _jour(a["au"], "au") if a.get("au") else aujourd_hui() + timedelta(days=apres)
    if fin < debut or (fin - debut).days > maximum - 1:
        raise RefusOutil("requete_invalide", f"La période va de 1 à {maximum} jours")
    return debut, fin


# ---------------------------------------------------------------------------
# Lecture
# ---------------------------------------------------------------------------

def lire_contexte(u: int, a: dict) -> object:
    """Ce que HAL sait de la personne : profil, limitations, lieux, objectifs, plan."""
    return contexte.texte(u)


def lire_memoire(u: int, a: dict) -> object:
    """MEM-1 : les quatre étages, du plus ancien au plus récent."""
    return memoire.texte(u)


def lire_echanges(u: int, a: dict) -> object:
    """MEM-8, version client : il n'a pas les derniers échanges sous les yeux,
    ils sont donc compris."""
    du = _jour(a["du"], "du") if a.get("du") else None
    au = _jour(a["au"], "au") if a.get("au") else None
    lignes = lister(
        """SELECT quand, auteur, client, moment, importance,
                  CASE WHEN char_length(contenu) > 1500
                       THEN left(contenu, 1500) || ' […]' ELSE contenu END AS contenu
             FROM echange
            WHERE id_utilisateur = %(u)s AND importance >= %(i)s
              AND (%(du)s::DATE IS NULL OR jour_de(quand) >= %(du)s::DATE)
              AND (%(au)s::DATE IS NULL OR jour_de(quand) <= %(au)s::DATE)
              AND (%(c)s = '' OR contenu ILIKE '%%' || %(c)s || '%%')
            ORDER BY id_echange DESC LIMIT %(l)s""",
        {"u": u, "i": int(a.get("importance_min") or 1), "du": du, "au": au,
         "c": (a.get("cherche") or "").strip(), "l": min(int(a.get("limite") or 10), 30)})
    return {"echanges": [sans_vides(x) for x in reversed(lignes)]}


def lire_aujourdhui(u: int, a: dict) -> object:
    """WID-8 : ce que l'écran Aujourd'hui montre, sans ce qui ne sert qu'à l'affichage."""
    from api.routeurs.appli import aujourdhui
    from api.securite import Appelant

    qui = un_seul("SELECT id_utilisateur, pseudo, role FROM utilisateur "
                  "WHERE id_utilisateur = %(u)s", {"u": u})
    assert qui is not None
    ecran = aujourdhui(Appelant(**qui))
    pseudos = {m["id"]: m["pseudo"] for m in ecran["membres"]}

    def pour(ligne: dict) -> dict:
        ligne = dict(ligne)
        ligne["pour"] = pseudos.get(ligne.get("pour"), ligne.get("pour"))
        return ligne

    taches = []
    for t in ecran["taches"]:
        t = pour(t)
        t["type"] = (t.get("type") or {}).get("libelle")
        for cle in ("id_tache", "code", "categorie", "actions_possibles"):
            t.pop(cle, None)
        taches.append(sans_vides(t))
    absences = []
    for x in ecran["absences"]:
        x = pour(x)
        if x.get("pour") != qui["pseudo"]:
            x.pop("lieu", None)
        absences.append(sans_vides(x))
    return {
        "jour": ecran["jour"],
        "moi": qui["pseudo"],
        "membres": list(pseudos.values()),
        "mon_planning": [sans_vides(e) for e in ecran["evenements"]],
        "taches_de_la_maison": taches,
        "conflit_a_trancher": ecran["conflit"] is not None,
        "absences": absences,
        "modes_alleges": [pour(x) for x in ecran["allegements"]],
        "minutes_de_taches_sur_7_jours": [pour(x) for x in ecran["equilibre"]],
        "weekends_proposes": ecran["propositions"],
        "note": "Les tâches sans heure sont des rappels de la journée. Une tâche en "
                "retard reste jusqu'à être faite. Le sport est dans lire_semaine."}


def lire_taches(u: int, a: dict) -> object:
    """Les tâches actives du foyer, leur rythme, pour qui, et leurs liens."""
    taches = lister(
        """SELECT t.id_tache, t.code, t.libelle, y.libelle AS type, t.duree_minutes,
                  CASE WHEN t.recurrente
                       THEN format('tous les %%s à %%s jours', t.periodicite_min_jours,
                                   t.periodicite_max_jours)
                       ELSE 'une fois' END AS rythme,
                  COALESCE(p.pseudo, 'à tour de rôle') AS pour,
                  t.heure_min, t.heure_max, t.si_pas_faite,
                  (SELECT array_agg(CASE WHEN l.id_de = t.id_tache THEN l.phrase_depuis
                                         ELSE l.phrase_vers END ORDER BY l.sorte)
                     FROM v_lien_tache l
                    WHERE l.actif AND (l.id_de = t.id_tache OR l.id_vers = t.id_tache))
                      AS liens
             FROM tache t
             LEFT JOIN type_tache y ON y.id_type_tache = t.id_type_tache
             LEFT JOIN utilisateur p ON p.id_utilisateur = t.id_utilisateur_defaut
            WHERE t.active AND t.categorie <> 'sport'
            ORDER BY y.ordre NULLS LAST, t.priorite, t.libelle""")
    return {"taches": [sans_vides(t) for t in taches]}


def lire_occurrences(u: int, a: dict) -> object:
    """Les tâches de la maison posées sur une période, faites ou non, et leur retard."""
    du, au = _periode(a, avant=7, apres=7, maximum=35)
    lignes = lister(
        """SELECT o.id_occurrence, o.tache_libelle AS tache, u.pseudo AS pour, o.statut,
                  o.debut, o.fin, o.rappel_journee AS journee_entiere, o.date_faite,
                  o.en_retard, o.jours_de_retard, o.nb_relances AS reports, o.motif
             FROM v_occurrence o JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
            WHERE o.categorie <> 'sport' AND u.id_foyer = foyer_de(%(u)s)
              AND (%(moi)s::BOOLEAN IS NOT TRUE OR o.id_utilisateur = %(u)s)
              AND COALESCE(o.debut, o.echeance_min) < debut_jour(%(au)s::DATE + 1)
              AND COALESCE(o.fin, o.echeance_max) > debut_jour(%(du)s::DATE)
            ORDER BY COALESCE(o.debut, o.echeance_min), o.priorite""",
        {"u": u, "du": du, "au": au, "moi": bool(a.get("seulement_moi"))})
    return {"periode": f"{du.isoformat()} au {au.isoformat()}",
            "occurrences": [sans_vides(x) for x in lignes]}


def lire_absences(u: int, a: dict) -> object:
    """Absences et voyages du foyer. De l'autre membre, les dates seulement (MCP-11)."""
    du, au = _periode(a, avant=7, apres=60, maximum=120)
    lignes = lister(
        """SELECT u.pseudo AS pour, a.id_utilisateur = %(u)s AS moi,
                  lower(a.periode) AS debut, upper(a.periode) AS fin,
                  CASE WHEN a.id_utilisateur = %(u)s THEN a.lieu END AS lieu, a.origine
             FROM absence a JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
            WHERE u.id_foyer = foyer_de(%(u)s)
              AND a.periode && tstzrange(debut_jour(%(du)s::DATE),
                                         debut_jour(%(au)s::DATE + 1), '[)')
            ORDER BY lower(a.periode)""",
        {"u": u, "du": du, "au": au})
    return {"periode": f"{du.isoformat()} au {au.isoformat()}",
            "absences": [sans_vides(x) for x in lignes]}


def lire_conflits(u: int, a: dict) -> object:
    """Les conflits horaires ouverts de la personne : ce qui était là, ce qui arrive."""
    lignes = lister(
        """SELECT c.id_conflit, s.libelle AS source,
                  oc.libelle AS existante, lower(oc.periode) AS debut_existante,
                  upper(oc.periode) AS fin_existante,
                  c.libelle AS nouvelle, lower(c.periode) AS debut_nouvelle,
                  upper(c.periode) AS fin_nouvelle
             FROM conflit c
             JOIN source s ON s.id_source = c.id_source
             JOIN occupation oc ON oc.id_occupation = c.id_occupation
            WHERE c.statut = 'en_attente' AND s.id_utilisateur = %(u)s
              AND upper(c.periode) > now()
            ORDER BY lower(c.periode)""", {"u": u})
    return {"conflits": [sans_vides(x) for x in lignes],
            "note": "Un conflit se tranche dans l'appli, depuis son bandeau d'Aujourd'hui."}


# ---------------------------------------------------------------------------
# Écriture : ce que HAL écrit déjà seul, et le résumé d'une conversation
# ---------------------------------------------------------------------------

def noter_conversation(u: int, a: dict) -> object:
    """MCP-12 : le résumé d'une conversation tenue dans un client, rangé dans
    les échanges. HAL le relit avec les derniers échanges, dans l'appli."""
    from api import operation

    texte = (a.get("resume") or "").strip()
    if not texte:
        raise RefusOutil("requete_invalide", "« resume » est vide")
    if len(texte) > RESUME_MAX:
        raise RefusOutil("resume_trop_long",
                         f"Un résumé tient en {RESUME_MAX} caractères, celui-ci en fait "
                         f"{len(texte)} : garde ce qui a été dit et décidé.")
    en_cours = operation.courante()
    ligne = executer(
        """INSERT INTO echange (id_utilisateur, auteur, moment, contenu, operation, client)
           VALUES (%(u)s, 'client', 'externe', %(t)s, %(o)s, %(c)s)
           RETURNING id_echange""",
        {"u": u, "t": texte, "o": en_cours.identifiant if en_cours else None,
         "c": (demandes.client_courant.get() or "client MCP")[:60]})
    assert ligne is not None
    return {"fait": "résumé déposé : HAL le lira dans l'appli",
            "id_echange": ligne["id_echange"]}


# ---------------------------------------------------------------------------
# Le catalogue
# ---------------------------------------------------------------------------

_PERIODE = {"du": {"type": "string", "description": "AAAA-MM-JJ"},
            "au": {"type": "string", "description": "AAAA-MM-JJ"}}

AJOUTES: tuple[Outil, ...] = (
    Outil("lire_contexte", "lecture",
          "Ce que HAL sait de la personne : profil, limitations et leur fiche, lieux "
          "de chaque discipline, objectifs, feuille de route, plan en cours, pause. "
          "À lire avant tout conseil sur le sport.",
          _objet({}), lire_contexte),
    Outil("lire_memoire", "lecture",
          "La mémoire de HAL en quatre étages, du plus ancien et résumé au plus "
          "récent : globale, trois derniers mois, mois en cours, semaine en cours.",
          _objet({}), lire_memoire),
    Outil("lire_echanges", "lecture",
          "Les échanges avec HAL, les plus récents compris : par mot (« genou »), par "
          "période, ou seulement les importants (importance_min 2 ou 3). Du plus "
          "ancien au plus récent, 30 au plus.",
          _objet({"cherche": {"type": "string"}, **_PERIODE,
                  "importance_min": {"type": "integer", "minimum": 1, "maximum": 3},
                  "limite": {"type": "integer", "minimum": 1, "maximum": 30}}),
          lire_echanges),
    Outil("lire_aujourdhui", "lecture",
          "La journée : mon planning du jour, les tâches de la maison du jour et en "
          "retard pour chacun, absences et modes allégés en cours, équilibre des "
          "tâches sur sept jours, week-ends proposés.",
          _objet({}), lire_aujourdhui),
    Outil("lire_taches", "lecture",
          "Les tâches de la maison : leur type, leur durée, leur rythme, pour qui, "
          "leur heure, et leurs liens avec les autres tâches.",
          _objet({}), lire_taches),
    Outil("lire_occurrences", "lecture",
          "Les tâches de la maison posées sur une période (35 jours au plus) : pour "
          "qui, quand, faites ou non, en retard. Sans dates, sept jours de part et "
          "d'autre d'aujourd'hui.",
          _objet({**_PERIODE, "seulement_moi": {"type": "boolean"}}), lire_occurrences),
    Outil("lire_absences", "lecture",
          "Les absences et les voyages du foyer, sur 120 jours au plus. Sans dates, "
          "de la semaine passée aux deux mois qui viennent.",
          _objet(_PERIODE), lire_absences),
    Outil("lire_conflits", "lecture",
          "Les conflits horaires à trancher : un événement d'un calendrier qui "
          "chevauche ce qui était déjà là.",
          _objet({}), lire_conflits),
    Outil("noter_conversation", "conversation",
          "Dépose le résumé de cette conversation pour HAL, en quelques lignes "
          "(2 000 caractères au plus) : ce qui a été dit et décidé. HAL le relira "
          "dans l'appli avec ses derniers échanges. À faire avant de finir une "
          "conversation qui lui a appris quelque chose.",
          _objet({"resume": {"type": "string"}}, ["resume"]), noter_conversation),
)

# Repris du coach tels quels. `lire_echanges` est remplacé par sa version client.
# Les séances proposées et les ajustements attendent déjà la validation de
# l'utilisateur (PLN, ACC-10) : un client les a comme HAL.
REPRIS = ("lire_chapitre", "lire_planning", "lire_semaine", "lire_seance", "lire_courses",
          "lire_sante",
          "lire_forme", "lire_mesures", "lire_progression", "lire_catalogue",
          "ajouter_memoire", "ecrire_memoire", "noter_mesure",
          "proposer_seances", "modifier_seance_proposee", "retirer_seance_proposee",
          "proposer_ajustement")

EXTERNE: dict[str, Outil] = {
    **{nom: OUTILS_DU_COACH[nom] for nom in REPRIS},
    **{outil.nom: outil for outil in AJOUTES},
    # ACC-1 : ce qui change le planning et la maison passe par une demande.
    **demandes.PAR_NOM,
}

# MCP-8 : ce qui écrit, annoncé comme tel au client. Le reste ne fait que lire.
ECRITURE = {"ajouter_memoire", "ecrire_memoire", "noter_mesure", "noter_conversation",
            "proposer_seances", "modifier_seance_proposee", "retirer_seance_proposee",
            "proposer_ajustement", *(nom for nom in demandes.PAR_NOM
                                     if nom != "lister_demandes")}


def chapitres_du_dossier() -> list[tuple[str, str]]:
    """MCP-7 : chaque chapitre et son titre, pour les ressources."""
    rendus = []
    for numero, texte in sorted(dossier.chapitres().items(),
                                key=lambda x: tuple(int(n) for n in x[0].split("."))):
        titre = texte.strip().splitlines()[0].lstrip("# ").strip() if texte.strip() else numero
        rendus.append((numero, titre))
    return rendus


def invite(u: int) -> str:
    """L'invite `hal` : le cadre, le socle du dossier, le contexte et la mémoire."""
    return "\n\n---\n\n".join([consigne(), dossier.base(), contexte.texte(u), memoire.texte(u)])
