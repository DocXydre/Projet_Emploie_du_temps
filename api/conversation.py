"""Ce que le bot sait faire, indépendamment de Telegram.

Tout ce qui se teste est ici : appairage, mise en forme des messages, exécution
des actions, heures de silence. `bot.py` ne fait plus que brancher ces fonctions
sur des commandes et des boutons.

La séparation n'est pas gratuite : sans elle, la seule façon de vérifier qu'un
bouton « fait » valide bien la bonne occurrence serait de parler à Telegram.
"""

from __future__ import annotations

from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

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

    La clé sert de mot de passe : sans elle, n'importe qui trouvant le nom du
    bot recevrait le planning. Un même compte peut changer de téléphone, d'où
    l'écrasement plutôt que le refus.
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

    `HOTE_PUBLIC` l'emporte toujours sur `defaut`, qui n'est qu'un repli tiré de
    la requête reçue. Sans cette priorité, interroger l'API depuis le Mac
    renverrait « localhost », adresse qui ne veut rien dire pour le téléphone.

    Deux formes de la même adresse. La première se colle dans un navigateur ou
    un champ d'abonnement ; la seconde, en `webcal://`, ouvre directement la
    boîte de dialogue d'abonnement quand on la touche sur un téléphone — ce qui
    évite de recopier un jeton de trente-deux caractères à la main.
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
               n.id_occurrence, n.type, n.contenu,
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
