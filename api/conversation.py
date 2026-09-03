"""Ce que le bot sait faire, indépendamment de Telegram.

Appairage, mise en forme des messages, exécution des actions, heures de
silence. `bot.py` ne fait que brancher ces fonctions sur des commandes et des
boutons.

Cette séparation permet de tester les actions du bot sans appeler Telegram.
"""

from __future__ import annotations

import re
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from psycopg.types.json import Json

from api.base import executer, lister, un_seul
from api.config import configuration

# Aucune notification entre ces deux heures : faire vibrer un téléphone à 3h du
# matin pour une poussière est le meilleur moyen de les faire couper.
SILENCE_DEBUT = time(23, 30)
SILENCE_FIN = time(7, 30)

ACTIONS = ("valider", "reporter", "refuser")


# ---------------------------------------------------------------------------
# Appairage
# ---------------------------------------------------------------------------

def appairer(cle_api: str, id_telegram: int) -> dict | None:
    """Associe une conversation Telegram à un compte, via sa clé d'API.

    La clé fait office de mot de passe. Un appairage existant est écrasé, ce
    qui permet de changer de téléphone.
    """
    return executer(
        """
        UPDATE utilisateur
           SET id_telegram = %(tg)s
         WHERE cle_api = %(cle)s AND actif
        RETURNING id_utilisateur, pseudo, role
        """,
        {"cle": cle_api.strip(), "tg": id_telegram},
    )


def url_collectable(url: str) -> str:
    """Ramène une URL d'abonnement à quelque chose qu'un client HTTP sait lire.

    Apple, Google et Outlook donnent des liens en `webcal://`. Ce préfixe sert
    seulement à ouvrir l'application Calendrier : derrière, c'est du HTTPS. On
    le remplace donc avant de collecter.
    """
    url = url.strip()
    if url.lower().startswith("webcal://"):
        return "https://" + url[len("webcal://"):]
    return url


def compte_de(id_telegram: int) -> dict | None:
    return un_seul(
        """
        SELECT id_utilisateur, pseudo, role FROM utilisateur
         WHERE id_telegram = %(tg)s AND actif
        """,
        {"tg": id_telegram},
    )


def desappairer(id_telegram: int) -> bool:
    resultat = executer(
        "UPDATE utilisateur SET id_telegram = NULL WHERE id_telegram = %(tg)s RETURNING pseudo",
        {"tg": id_telegram},
    )
    return resultat is not None


# ---------------------------------------------------------------------------
# Abonnement au calendrier
# ---------------------------------------------------------------------------

def url_calendrier(id_utilisateur: int, defaut: str | None = None) -> dict | None:
    """URL d'abonnement au flux iCalendar, ou None si l'hôte est inconnu.

    `HOTE_PUBLIC` l'emporte sur `defaut`, qui n'est qu'un repli tiré de la
    requête : interrogée depuis le Mac, l'API renverrait sinon « localhost ».

    Deux formes de la même adresse, dont une en `webcal://` qui ouvre
    directement la boîte d'abonnement d'un téléphone.
    """
    ligne = un_seul(
        "SELECT jeton_calendrier FROM utilisateur WHERE id_utilisateur = %(u)s AND actif",
        {"u": id_utilisateur},
    )
    if ligne is None:
        return None

    hote = (configuration().hote_public or defaut or "").strip().rstrip("/")
    if not hote:
        return None
    hote = hote.split("://", 1)[-1]

    chemin = f"{hote}/planning.ics?cle={ligne['jeton_calendrier']}"
    return {"url": f"http://{chemin}", "webcal": f"webcal://{chemin}", "hote": hote}


def renouveler_calendrier(id_utilisateur: int) -> str | None:
    """Invalide l'abonnement en place et en rend un nouveau."""
    ligne = un_seul(
        "SELECT renouveler_jeton_calendrier(%(u)s) AS jeton", {"u": id_utilisateur}
    )
    return ligne["jeton"] if ligne else None


# ---------------------------------------------------------------------------
# Heures de silence
# ---------------------------------------------------------------------------

def en_silence(maintenant: datetime | None = None) -> bool:
    fuseau = ZoneInfo(configuration().fuseau)
    heure = (maintenant or datetime.now(fuseau)).astimezone(fuseau).time()
    # La plage traverse minuit : elle est vraie de 23h30 à 7h30.
    return heure >= SILENCE_DEBUT or heure < SILENCE_FIN


# ---------------------------------------------------------------------------
# Actions sur une occurrence
# ---------------------------------------------------------------------------

def executer_action(action: str, id_occurrence: int, id_utilisateur: int) -> str:
    """Applique une action et renvoie ce qu'il y a à répondre.

    Les erreurs métier remontent telles quelles : la base écrit déjà ses refus
    en français, il n'y a pas à les réécrire ici.
    """
    if action not in ACTIONS:
        raise ValueError(f"Action inconnue : {action}")

    if action == "valider":
        executer(
            "SELECT valider_occurrence(%(o)s, %(u)s, NULL)",
            {"o": id_occurrence, "u": id_utilisateur},
        )
        return "C'est noté, merci."

    if action == "reporter":
        reporte = executer(
            """
            UPDATE occurrence o
               SET statut  = 'a_placer',
                   creneau = NULL,
                   fenetre = fenetre_pour(o.rappel_journee, now(),
                                          upper(o.fenetre) + INTERVAL '1 day'),
                   motif   = 'Reportée depuis le bot'
              FROM tache t
             WHERE t.id_tache = o.id_tache
               AND o.id_occurrence = %(o)s
               AND t.reportable
            RETURNING o.id_occurrence
            """,
            {"o": id_occurrence},
        )
        if reporte is None:
            return "Celle-là ne peut pas être repoussée : la repousser ne résoudrait rien."
        return "Reportée à demain."

    remplacante = executer(
        """
        WITH refusee AS (
            UPDATE occurrence SET statut = 'abandonnee', motif = 'Refusée depuis le bot'
             WHERE id_occurrence = %(o)s
            RETURNING id_tache, fenetre, id_occurrence
        )
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine,
                                id_occurrence_source, motif)
        SELECT r.id_tache, NULL, r.fenetre, 'manuelle', r.id_occurrence,
               'À réassigner après refus'
          FROM refusee r
        RETURNING id_occurrence
        """,
        {"o": id_occurrence},
    )
    if remplacante is None:
        return "Impossible de refuser celle-là."
    return "Refusée. Elle reste à faire, sans assigné."


# ---------------------------------------------------------------------------
# Mise en forme
# ---------------------------------------------------------------------------

def _heure(instant: datetime) -> str:
    return instant.astimezone(ZoneInfo(configuration().fuseau)).strftime("%Hh%M")


def _jour(instant: datetime) -> str:
    return instant.astimezone(ZoneInfo(configuration().fuseau)).strftime("%d/%m")


def planning_du_jour(id_utilisateur: int, dans_jours: int = 0) -> str:
    lignes = lister(
        """
        SELECT nature, categorie, libelle, debut, fin, journee_entiere, lieu, motif
          FROM v_planning
         WHERE id_utilisateur = %(u)s
           AND debut < debut_jour(jour_de(now()) + %(j)s + 1)
           AND fin   > debut_jour(jour_de(now()) + %(j)s)
         ORDER BY journee_entiere, debut
        """,
        {"u": id_utilisateur, "j": dans_jours},
    )
    if not lignes:
        return "Rien de prévu."

    horaires = [x for x in lignes if not x["journee_entiere"]]
    rappels = [x for x in lignes if x["journee_entiere"]]

    morceaux = []
    for ligne in horaires:
        detail = f" — {ligne['lieu']}" if ligne["lieu"] else ""
        morceaux.append(f"{_heure(ligne['debut'])}–{_heure(ligne['fin'])}  "
                        f"{ligne['libelle']}{detail}")
    for ligne in rappels:
        morceaux.append(f"○ {ligne['libelle']}")

    return "\n".join(morceaux)


def a_valider(id_utilisateur: int, dans_jours: int = 0) -> list[dict]:
    """Ce qu'on peut cocher maintenant : le jour même, et ce qui traîne.

    Attendre la relance du soir pour pouvoir valider une tâche est un défaut :
    on fait la vaisselle quand on la fait, pas à 21h. Cette liste rend la main
    à tout moment.
    """
    return lister(
        """
        SELECT o.id_occurrence, o.tache_libelle, o.tache_code, o.statut,
               o.debut, o.jours_de_retard, o.actions_possibles, o.en_retard
          FROM v_occurrence o
         WHERE o.id_utilisateur = %(u)s
           AND o.statut IN ('planifiee', 'notifiee')
           AND o.debut IS NOT NULL
           AND (o.en_retard OR jour_de(o.debut) <= jour_de(now()) + %(d)s)
         ORDER BY o.en_retard DESC, o.debut
        """,
        {"u": id_utilisateur, "d": dans_jours},
    )


def seances_sport(id_utilisateur: int, limite: int = 5) -> list[dict]:
    """Prochaines séances placées, trajet compris."""
    return lister(
        """
        SELECT o.id_occurrence, lower(o.creneau) AS debut, upper(o.creneau) AS fin,
               l.libelle AS lieu
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_utilisateur = %(u)s
           AND t.categorie = 'sport'
           AND o.creneau IS NOT NULL
           AND upper(o.creneau) > now()
           AND o.statut IN ('planifiee', 'notifiee')
         ORDER BY lower(o.creneau)
         LIMIT %(n)s
        """,
        {"u": id_utilisateur, "n": limite},
    )


def prochaine_chose(id_utilisateur: int) -> str:
    """Une ligne : ce qui vient ensuite, obligation ou tâche.

    Sert d'en-tête au menu, pour avoir l'information sans cliquer.
    """
    ligne = un_seul(
        """
        SELECT nature, categorie, libelle, debut, journee_entiere, lieu
          FROM v_planning
         WHERE id_utilisateur = %(u)s
           AND nature <> 'proposition'
           AND fin > now()
         ORDER BY debut
         LIMIT 1
        """,
        {"u": id_utilisateur},
    )
    if ligne is None:
        return "Rien de prévu."

    quand = _jour(ligne["debut"])
    if not ligne["journee_entiere"]:
        quand += f" à {_heure(ligne['debut'])}"

    ou = f" — {ligne['lieu']}" if ligne["lieu"] else ""
    return f"{ligne['libelle']}, {quand}{ou}"


def taches_en_retard(id_utilisateur: int) -> list[dict]:
    return lister(
        """
        SELECT id_occurrence, tache_libelle, jours_de_retard, nb_relances
          FROM v_taches_en_retard
         WHERE id_utilisateur = %(u)s
         ORDER BY jours_de_retard DESC
        """,
        {"u": id_utilisateur},
    )


def etat_du_stock(id_utilisateur: int) -> str:
    articles = lister("SELECT * FROM v_stock ORDER BY code")
    if not articles:
        return "Aucun article suivi."

    morceaux = []
    for article in articles:
        etat = f"{article['libelle']} : {article['quantite_propre']} propre(s)"
        if article["en_sechage"]:
            dispo = article["disponible_le"]
            etat += f", dispo le {_jour(dispo)} à {_heure(dispo)}"
        morceaux.append(etat)

    ruptures = lister("SELECT * FROM projeter_stock(%(u)s)", {"u": id_utilisateur})
    for rupture in ruptures:
        quand = rupture["jour_rupture"].strftime("%d/%m")
        if rupture["alerte"]:
            morceaux.append(f"⚠ {rupture['article']} : trop tard pour laver avant le {quand}")
        else:
            morceaux.append(f"Lessive avant le {_jour(rupture['echeance_lessive'])} "
                            f"à {_heure(rupture['echeance_lessive'])} "
                            f"(rupture le {quand})")

    return "\n".join(morceaux)


def _recollecter(code_source: str) -> dict:
    """Recollecte une source et replace les tâches. Utilisé après un filtre modifié.

    La collecte fait le ménage seule : les cours à venir dont la clé n'apparaît
    plus dans le flux retenu sont supprimés. Écarter un cours suffit donc à le
    faire disparaître du calendrier.
    """
    from api.collecteurs.service import collecter_source
    bilan = collecter_source(code_source)

    from api.ordonnanceur import placer
    bilan["occurrences_replacees"] = placer()
    return bilan


def cours_ecartes(code_source: str = "IDMC_ICS") -> list[str]:
    ligne = un_seul(
        "SELECT configuration -> 'cours_ecartes' AS liste FROM source WHERE code = %(c)s",
        {"c": code_source},
    )
    return list((ligne or {}).get("liste") or [])


def ecarter_cours(libelle: str, code_source: str = "IDMC_ICS") -> dict | None:
    """Ajoute un cours à la liste de ceux qu'on ne suit pas, puis recollecte.

    Les UE au choix arrivent toutes dans le même flux : l'ADE publie le
    traitement d'images comme la recherche opérationnelle, à charge pour
    l'étudiant de savoir laquelle il suit.
    """
    libelle = libelle.strip()
    liste = cours_ecartes(code_source)
    if libelle.lower() not in [c.lower() for c in liste]:
        liste.append(libelle)

    return _enregistrer_ecartes(liste, code_source)


def reprendre_cours(libelle: str, code_source: str = "IDMC_ICS") -> dict | None:
    """Retire un cours de la liste : on le suit de nouveau."""
    liste = [c for c in cours_ecartes(code_source) if c.lower() != libelle.strip().lower()]
    return _enregistrer_ecartes(liste, code_source)


def _enregistrer_ecartes(liste: list[str], code_source: str) -> dict | None:
    modifiee = executer(
        "UPDATE source "
        "   SET configuration = COALESCE(configuration, '{}'::JSONB) "
        "                       || jsonb_build_object('cours_ecartes', %(l)s::JSONB) "
        " WHERE code = %(c)s RETURNING code",
        {"l": Json(liste), "c": code_source},
    )
    if modifiee is None:
        return None

    bilan = _recollecter(code_source)
    bilan["cours_ecartes"] = liste
    return bilan


def groupe_actuel(code_source: str = "IDMC_ICS") -> str | None:
    ligne = un_seul(
        "SELECT configuration ->> 'groupe' AS groupe FROM source WHERE code = %(c)s",
        {"c": code_source},
    )
    return (ligne or {}).get("groupe")


def changer_groupe(groupe: int, code_source: str = "IDMC_ICS") -> dict | None:
    """Change le groupe de TD suivi, et recollecte dans la foulée.

    La configuration est fusionnée et non remplacée : le profil de collecte,
    les langues et l'horizon restent en place.

    La collecte qui suit fait le ménage toute seule. Les cours à venir dont la
    clé externe n'apparaît plus dans le flux retenu sont supprimés, donc ceux de
    l'ancien groupe disparaissent et ceux du nouveau sont créés.
    """
    modifiee = executer(
        "UPDATE source "
        "   SET configuration = COALESCE(configuration, '{}'::JSONB) "
        "                       || jsonb_build_object('groupe', %(g)s::INT) "
        " WHERE code = %(c)s "
        "RETURNING code, configuration",
        {"g": groupe, "c": code_source},
    )
    if modifiee is None:
        return None
    return _recollecter(code_source)


def articles_stock() -> list[dict]:
    """Les articles suivis, pour construire les boutons de recalage."""
    return lister("SELECT code, libelle, quantite_propre, quantite_totale "
                  "  FROM article_travail ORDER BY code")


def recaler_stock(code: str, propre: int) -> dict | None:
    """Déclare le stock propre réel d'un article, et replace la lessive."""
    resultat = un_seul("SELECT * FROM recaler_uniforme(%(c)s, %(q)s)",
                       {"c": code.upper(), "q": propre})
    if resultat is not None:
        from api.ordonnanceur import placer
        placer()
    return resultat


def taches_declarables(id_utilisateur: int) -> list[dict]:
    """Tâches qu'on peut déclarer faites spontanément.

    Le sport en est écarté : une séance se valide par son occurrence, qui porte
    un lieu et un horaire.
    """
    return lister(
        """
        SELECT t.code, t.libelle, t.categorie
          FROM tache t
         WHERE t.active AND t.categorie <> 'sport'
           AND (t.id_utilisateur_defaut IS NULL
                OR t.id_utilisateur_defaut = %(u)s)
         ORDER BY t.libelle
        """,
        {"u": id_utilisateur},
    )


def declarer_faite(id_utilisateur: int, code_tache: str) -> str:
    """« C'est fait », même si ce n'était pas prévu aujourd'hui."""
    resultat = un_seul(
        "SELECT declarer_faite(%(u)s, %(c)s) AS id_occurrence",
        {"u": id_utilisateur, "c": code_tache.upper()},
    )
    if resultat is None:
        return "Tâche inconnue."

    ligne = un_seul(
        "SELECT tache_libelle, echeance_max FROM v_occurrence "
        " WHERE id_tache = (SELECT id_tache FROM tache WHERE code = %(c)s) "
        "   AND statut IN ('a_placer', 'planifiee', 'notifiee') "
        " ORDER BY echeance_max LIMIT 1",
        {"c": code_tache.upper()},
    )
    if ligne is None:
        return "C'est noté."
    return (f"{ligne['tache_libelle']} : c'est noté.\n"
            f"Prochaine échéance le {_jour(ligne['echeance_max'])}.")


def ajouter_occupation(id_utilisateur: int, libelle: str,
                       debut: datetime, fin: datetime,
                       lieu: str | None = None) -> dict | None:
    """Pose une occupation saisie à la main, et replace ce qui tombait dessus."""
    resultat = un_seul(
        "SELECT ajouter_occupation(%(u)s, %(l)s, %(d)s, %(f)s, 'autre', %(lieu)s) "
        "    AS id_occupation",
        {"u": id_utilisateur, "l": libelle, "d": debut, "f": fin, "lieu": lieu},
    )
    if resultat is not None:
        from api.ordonnanceur import placer
        placer()
    return resultat


def lire_creneau(mots: list[str], fuseau=None) -> tuple[str, datetime, datetime] | None:
    """Lit « Médecin 12/09 14h 16h » et rend le libellé et les deux instants.

    Le jour se donne en JJ/MM, ou se laisse de côté pour aujourd'hui. Les heures
    s'écrivent 14h, 14h30 ou 14:30. Le libellé est tout ce qui reste, ce qui
    permet de l'écrire sans guillemets.
    """
    fuseau = fuseau or ZoneInfo(configuration().fuseau)
    maintenant = datetime.now(fuseau)

    jour = None
    heures: list[tuple[int, int]] = []
    restant: list[str] = []

    for mot in mots:
        date = re.fullmatch(r"(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?", mot)
        heure = re.fullmatch(r"(\d{1,2})[h:](\d{2})?", mot)

        if date and jour is None:
            annee = int(date.group(3) or maintenant.year)
            annee += 2000 if annee < 100 else 0
            try:
                jour = datetime(annee, int(date.group(2)), int(date.group(1)),
                                tzinfo=fuseau).date()
            except ValueError:
                return None
        elif heure and len(heures) < 2:
            heures.append((int(heure.group(1)), int(heure.group(2) or 0)))
        else:
            restant.append(mot)

    if len(heures) != 2 or not restant:
        return None

    jour = jour or maintenant.date()
    debut = datetime(jour.year, jour.month, jour.day, *heures[0], tzinfo=fuseau)
    fin = datetime(jour.year, jour.month, jour.day, *heures[1], tzinfo=fuseau)

    # « 22h 2h » : la fin appartient au lendemain.
    if fin <= debut:
        fin += timedelta(days=1)

    return " ".join(restant), debut, fin


def declarer_absence(id_utilisateur: int, debut: datetime, fin: datetime,
                     lieu: str | None = None) -> dict | None:
    return executer(
        """
        INSERT INTO absence (id_utilisateur, periode, lieu, origine)
        VALUES (%(u)s, tstzrange(%(debut)s, %(fin)s, '[)'), %(lieu)s, 'manuelle')
        RETURNING id_absence, lower(periode) AS debut, upper(periode) AS fin, lieu
        """,
        {"u": id_utilisateur, "debut": debut, "fin": fin, "lieu": lieu},
    )


def partir(id_utilisateur: int, lieu: str | None = None) -> dict | None:
    """« Je pars maintenant », sans savoir quand je rentre.

    Le cas le plus fréquent, et celui qu'aucune déduction ne couvre : on monte
    en voiture, on décide sur place. L'absence court jusqu'à la prochaine
    obligation connue, et se ferme au retour.
    """
    ligne = un_seul("SELECT partir_maintenant(%(u)s, %(l)s) AS id_absence",
                    {"u": id_utilisateur, "l": lieu})
    if ligne is None:
        return None
    return un_seul(
        "SELECT id_absence, lower(periode) AS debut, upper(periode) AS fin, lieu "
        "  FROM absence WHERE id_absence = %(id)s",
        {"id": ligne["id_absence"]},
    )


def rentrer(id_utilisateur: int) -> dict | None:
    """« Je suis rentré ». Ferme l'absence en cours à l'instant présent.

    Rend None si aucune absence n'était en cours : ce n'est pas une erreur,
    seulement une nouvelle à annoncer autrement.
    """
    ligne = un_seul("SELECT terminer_absence(%(u)s) AS id_absence",
                    {"u": id_utilisateur})
    if ligne is None or ligne["id_absence"] is None:
        return None

    return un_seul(
        "SELECT id_absence, lower(periode) AS debut, upper(periode) AS fin, lieu "
        "  FROM absence WHERE id_absence = %(id)s",
        {"id": ligne["id_absence"]},
    )


def absences_a_venir(id_utilisateur: int) -> list[dict]:
    return lister(
        """
        SELECT id_absence, lower(periode) AS debut, upper(periode) AS fin, lieu,
               (periode @> now()) AS en_cours
          FROM absence
         WHERE id_utilisateur = %(u)s AND upper(periode) > now()
         ORDER BY lower(periode)
        """,
        {"u": id_utilisateur},
    )


def lire_periode(mots: list[str]) -> tuple[datetime, datetime] | None:
    """Interprète « JJ/MM JJ/MM » ou « JJ/MM » (une seule journée).

    Volontairement rudimentaire : deviner « ce week-end » ou « vendredi soir »
    demanderait d'interpréter la langue, et se tromper sur des dates gèlerait
    des tâches sans qu'on comprenne pourquoi.
    """
    fuseau = ZoneInfo(configuration().fuseau)
    aujourd_hui = datetime.now(fuseau)
    dates = []

    for mot in mots[:2]:
        morceaux = mot.split("/")
        if len(morceaux) < 2 or not all(m.isdigit() for m in morceaux[:2]):
            return None
        jour, mois = int(morceaux[0]), int(morceaux[1])
        annee = int(morceaux[2]) if len(morceaux) > 2 else aujourd_hui.year

        try:
            date = datetime(annee, mois, jour, tzinfo=fuseau)
        except ValueError:
            return None

        # Une date déjà passée désigne l'année suivante : en décembre, « 05/01 »
        # veut dire janvier prochain.
        if len(morceaux) == 2 and date.date() < aujourd_hui.date() - timedelta(days=1):
            date = date.replace(year=annee + 1)
        dates.append(date)

    if not dates:
        return None

    debut = dates[0]
    fin = (dates[1] if len(dates) > 1 else debut) + timedelta(days=1)
    return (debut, fin) if fin > debut else None


def conflits_a_arbitrer() -> list[dict]:
    return lister(
        """
        SELECT id_conflit, libelle_existante, debut_existante,
               libelle_nouvelle, debut_nouvelle, lieu_nouvelle
          FROM v_conflit
         WHERE statut = 'en_attente' AND a_arbitrer
         ORDER BY debut_nouvelle
        """
    )


def decrire_conflit(conflit: dict) -> str:
    quand = f"{_jour(conflit['debut_nouvelle'])} à {_heure(conflit['debut_nouvelle'])}"
    lieu = f" ({conflit['lieu_nouvelle']})" if conflit["lieu_nouvelle"] else ""
    return (f"Deux cours le {quand} :\n"
            f"1. {conflit['libelle_existante']}\n"
            f"2. {conflit['libelle_nouvelle']}{lieu}\n"
            f"Lequel gardes-tu ?")


def trancher_conflit(id_conflit: int, garder: str, id_utilisateur: int) -> str:
    conflit = un_seul(
        "SELECT * FROM conflit WHERE id_conflit = %(id)s AND statut = 'en_attente'",
        {"id": id_conflit},
    )
    if conflit is None:
        return "Ce conflit a déjà été tranché."

    if garder == "nouvelle":
        executer("DELETE FROM occupation WHERE id_occupation = %(o)s",
                 {"o": conflit["id_occupation"]})
        executer(
            """
            INSERT INTO occupation (id_utilisateur, id_source, type, libelle,
                                    periode, lieu, details, cle_externe)
            VALUES (%(u)s, %(s)s, 'cours', %(libelle)s, %(periode)s,
                    %(lieu)s, %(details)s, %(cle)s)
            """,
            {
                "u": id_utilisateur, "s": conflit["id_source"],
                "libelle": conflit["libelle"], "periode": conflit["periode"],
                "lieu": conflit["lieu"], "details": conflit["details"],
                "cle": conflit["cle_externe"],
            },
        )

    executer(
        """
        UPDATE conflit SET statut = 'resolu', choix = %(choix)s, date_resolution = now()
         WHERE id_conflit = %(id)s
        """,
        {"id": id_conflit, "choix": garder},
    )
    return "C'est enregistré." if garder == "existante" else "Remplacé."


# ---------------------------------------------------------------------------
# File d'attente
# ---------------------------------------------------------------------------

def notifications_a_envoyer(limite: int = 20) -> list[dict]:
    """Notifications en attente, pour les comptes reliés à Telegram."""
    return lister(
        """
        SELECT n.id_notification, n.id_utilisateur, u.id_telegram,
               n.id_occurrence, n.id_proposition, n.type, n.contenu,
               o.tache_libelle, o.actions_possibles
          FROM notification n
          JOIN utilisateur u ON u.id_utilisateur = n.id_utilisateur
          LEFT JOIN v_occurrence o ON o.id_occurrence = n.id_occurrence
         WHERE n.statut = 'a_envoyer'
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


def prochain_rappel(id_utilisateur: int) -> datetime:
    """Heure de la prochaine sortie de silence, pour information."""
    fuseau = ZoneInfo(configuration().fuseau)
    maintenant = datetime.now(fuseau)
    fin = maintenant.replace(hour=SILENCE_FIN.hour, minute=SILENCE_FIN.minute,
                             second=0, microsecond=0)
    return fin if fin > maintenant else fin + timedelta(days=1)
