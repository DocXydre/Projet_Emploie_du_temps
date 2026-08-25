"""Orchestration d'une collecte : récupérer, filtrer, réconcilier.

Ce module ne connaît pas HTTP. L'endpoint et l'ordonnanceur l'appellent de la
même façon, pour qu'il n'existe pas deux chemins de code pour la même
opération.
"""

import logging
from datetime import datetime, timedelta

import psycopg

from api.base import connexion, un_seul
from api.collecteurs.ics import Seance
from api.collecteurs.ics import collecter as collecter_flux

LOG = logging.getLogger(__name__)

# COL-11 : au-delà de ce délai, un conflit ne mérite pas qu'on dérange.
DELAI_ARBITRAGE = timedelta(days=14)


class CollecteImpossible(Exception):
    """La source ne peut pas être collectée : ni flux, ni URL, ni utilisateur."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _enregistrer_conflit(cur, id_source: int, id_utilisateur: int,
                         seance: Seance) -> tuple[str, str | None]:
    """Consigne une séance rejetée pour cause de chevauchement.

    Renvoie le sort réservé à la séance et, le cas échéant, sa description.
    Le premier élément vaut « arbitrable », « lointain » ou « connu » : une
    collecte doit pouvoir rendre compte de chaque séance lue, sinon des cours
    disparaissent sans que personne ne s'en aperçoive.
    """
    # COL-11 : un conflit à plus de deux semaines sera souvent corrigé à la
    # source. On ne demande pas d'arbitrage, mais on le compte.
    if seance.debut > datetime.now(seance.debut.tzinfo) + DELAI_ARBITRAGE:
        return "lointain", None

    cur.execute(
        """
        SELECT id_occupation FROM occupation
         WHERE id_utilisateur = %(u)s
           AND type IN ('cours', 'travail')
           AND periode && tstzrange(%(debut)s, %(fin)s, '[)')
         ORDER BY lower(periode)
         LIMIT 1
        """,
        {"u": id_utilisateur, "debut": seance.debut, "fin": seance.fin},
    )
    existante = cur.fetchone()
    if existante is None:
        return "lointain", None

    cur.execute(
        """
        INSERT INTO conflit (id_occupation, id_source, cle_externe, libelle,
                             periode, lieu, details)
        VALUES (%(occupation)s, %(source)s, %(cle)s, %(libelle)s,
                tstzrange(%(debut)s, %(fin)s, '[)'), %(lieu)s, %(details)s)
        ON CONFLICT (id_source, cle_externe, id_occupation) DO NOTHING
        RETURNING id_conflit
        """,
        {
            "occupation": existante["id_occupation"],
            "source": id_source,
            "cle": seance.cle_externe,
            "libelle": seance.libelle,
            "debut": seance.debut,
            "fin": seance.fin,
            "lieu": seance.lieu,
            "details": seance.details,
        },
    )
    if cur.fetchone() is None:
        return "connu", None   # conflit déjà signalé lors d'une collecte précédente

    quand = seance.debut.astimezone().strftime("%d/%m à %Hh%M")
    cur.execute(
        "INSERT INTO notification (id_utilisateur, type, contenu) VALUES (%(u)s, 'alerte', %(c)s)",
        {
            "u": id_utilisateur,
            "c": f"Deux occupations le {quand} : « {seance.libelle} » entre en "
                 f"conflit avec ce qui est déjà prévu. Laquelle garder ?",
        },
    )
    return "arbitrable", f"{seance.libelle} le {quand}"


def reconcilier(id_source: int, id_utilisateur: int, seances: list[Seance],
                type_occupation: str = "cours") -> dict:
    """Met la base au diapason de la source, sans jamais dupliquer.

    La clé externe décide : on met à jour ce qui existe, on insère ce qui est
    nouveau, et on retire ce qui a disparu du flux **dans le futur seulement**.
    Un cours passé qui n'est plus publié a quand même eu lieu.
    """
    cles = [s.cle_externe for s in seances]
    cree = modifie = 0
    conflits: list[str] = []
    # Chaque séance lue doit se retrouver dans exactement un compteur : une
    # collecte dont les chiffres ne tombent pas juste cache des cours perdus.
    autres = {"lointain": 0, "connu": 0, "deja_arbitre": 0}

    with connexion() as conn, conn.cursor() as cur:
        # Un conflit déjà tranché en faveur de l'existant n'est pas reposé à
        # la collecte suivante.
        cur.execute(
            """
            SELECT cle_externe FROM conflit
             WHERE id_source = %(s)s AND statut = 'resolu' AND choix = 'existante'
            """,
            {"s": id_source},
        )
        ecartees = {ligne["cle_externe"] for ligne in cur.fetchall()}

        for seance in seances:
            if seance.cle_externe in ecartees:
                autres["deja_arbitre"] += 1
                continue

            try:
                # Un point de reprise par séance : une séance en conflit ne doit
                # pas faire échouer toute la collecte.
                with conn.transaction():
                    cur.execute(
                        """
                        INSERT INTO occupation (id_utilisateur, id_source, type, libelle,
                                                periode, lieu, details, cle_externe,
                                                date_collecte)
                        VALUES (%(utilisateur)s, %(source)s, %(type)s, %(libelle)s,
                                tstzrange(%(debut)s, %(fin)s, '[)'),
                                %(lieu)s, %(details)s, %(cle)s, now())
                        ON CONFLICT (id_source, cle_externe) DO UPDATE
                           SET libelle       = EXCLUDED.libelle,
                               periode       = EXCLUDED.periode,
                               lieu          = EXCLUDED.lieu,
                               details       = EXCLUDED.details,
                               date_collecte = now()
                        RETURNING (xmax = 0) AS insere
                        """,
                        {
                            "utilisateur": id_utilisateur,
                            "source": id_source,
                            "type": type_occupation,
                            "libelle": seance.libelle,
                            "debut": seance.debut,
                            "fin": seance.fin,
                            "lieu": seance.lieu,
                            "details": seance.details,
                            "cle": seance.cle_externe,
                        },
                    )
                    ligne = cur.fetchone()
                    if ligne and ligne["insere"]:
                        cree += 1
                    else:
                        modifie += 1

            except psycopg.errors.ExclusionViolation:
                # La source publie deux occupations au même moment. C'est une
                # incohérence de l'emploi du temps, pas de notre code.
                sort, description = _enregistrer_conflit(cur, id_source, id_utilisateur, seance)
                if description:
                    conflits.append(description)
                else:
                    autres[sort] += 1
                LOG.warning("Séance en conflit horaire (%s) : %s le %s",
                            sort, seance.libelle, seance.debut.isoformat())

        cur.execute(
            """
            DELETE FROM occupation
             WHERE id_source = %(source)s
               AND cle_externe IS NOT NULL
               AND NOT (cle_externe = ANY(%(cles)s::TEXT[]))
               AND lower(periode) > now()
            RETURNING id_occupation
            """,
            {"source": id_source, "cles": cles},
        )
        annules = len(cur.fetchall())

        cur.execute(
            "UPDATE source SET derniere_collecte = now(), etat = 'ok' WHERE id_source = %(s)s",
            {"s": id_source},
        )

    return {
        "crees": cree,
        "mis_a_jour": modifie,
        "annules": annules,
        "conflits": conflits,
        "conflits_lointains": autres["lointain"],
        "conflits_deja_signales": autres["connu"],
        "ecartees_par_arbitrage": autres["deja_arbitre"],
    }


def collecter_source(code: str, id_utilisateur: int | None = None,
                     texte_ics: str | None = None) -> dict:
    """Collecte une source de bout en bout.

    `id_utilisateur` ne sert que de repli : c'est la source qui sait à qui
    appartient son emploi du temps.
    """
    source = un_seul(
        """
        SELECT id_source, code, url, mode_collecte, configuration, id_utilisateur, active
          FROM source WHERE code = %(c)s
        """,
        {"c": code},
    )
    if source is None:
        raise CollecteImpossible("introuvable", f"Source {code} inconnue")

    if source["mode_collecte"] != "ics":
        raise CollecteImpossible(
            "collecte_impossible", f"La source {code} n'est pas un flux iCalendar")

    if not source["url"] and texte_ics is None:
        raise CollecteImpossible(
            "url_absente",
            f"La source {code} n'a pas encore d'URL. Envoyez-la avec PATCH /sources/{code}.")

    proprietaire = source["id_utilisateur"] or id_utilisateur
    if proprietaire is None:
        raise CollecteImpossible(
            "sans_proprietaire",
            f"La source {code} n'est rattachée à personne : impossible de savoir "
            f"à qui affecter les occupations collectées.")

    reglages = source["configuration"] or {}
    resultat = collecter_flux(source["url"], reglages, texte_ics)
    bilan = reconcilier(source["id_source"], proprietaire, resultat["seances"],
                        reglages.get("type_occupation", "cours"))

    compte_rendu = {
        "source": code,
        "lues": resultat["lues"],
        "rejets": resultat["rejets"],
        **bilan,
    }

    # Contrôle de cohérence : toute séance lue doit se retrouver dans l'une
    # des catégories du bilan. Sinon des cours disparaissent en silence entre
    # le flux et le planning.
    manquantes = compte_rendu["lues"] - (
        compte_rendu["crees"]
        + compte_rendu["mis_a_jour"]
        + len(compte_rendu["conflits"])
        + compte_rendu["conflits_lointains"]
        + compte_rendu["conflits_deja_signales"]
        + compte_rendu["ecartees_par_arbitrage"]
        + sum(compte_rendu["rejets"].values())
    )
    if manquantes:
        LOG.error("Collecte %s : %d séance(s) non comptabilisée(s)", code, manquantes)
        compte_rendu["non_comptabilisees"] = manquantes

    return compte_rendu


def sources_a_collecter() -> list[str]:
    """Sources actives dont la fréquence est écoulée."""
    lignes = un_seul(
        """
        SELECT array_agg(code ORDER BY code) AS codes FROM source
         WHERE active
           AND mode_collecte = 'ics'
           AND url IS NOT NULL
           AND (derniere_collecte IS NULL
                OR now() - derniere_collecte > make_interval(hours => frequence_heures))
        """
    )
    return (lignes or {}).get("codes") or []
