"""Ce que le bot affiche pour le coach : des écrans, c'est-à-dire un texte et
des rangées de boutons.                                          (section 9.4)

Tout ici est synchrone et se teste sans parler à Telegram : `bot.py` ne fait que
brancher. Le bot lit la même réponse que l'application : il affiche le message
du coach, puis un bouton par action de chaque élément (COA-19). Un type
d'élément qu'il ne connaît pas est ignoré, jamais une erreur.

Les rappels des boutons commencent par « co: » et tiennent en 64 octets.
"""

import html
import re
import uuid
from datetime import date, datetime, time, timedelta

import psycopg

from api.base import lister, un_seul
from api.coach import appel, contexte, outils, planifie
from api.coach.clair import aujourd_hui, fuseau, jour_en_clair, lundi_de, maintenant
from api.ecran import Ecran
from api.erreurs import refus_coach
from api.routeurs import coach as routes
from api.securite import Appelant

MAX_TEXTE = 3900

DISCIPLINES = {"musculation": "musculation", "muscu": "musculation", "salle": "musculation",
               "course": "course", "footing": "course", "cardio": "cardio"}
UNITES = {"poids": "kg", "tour_taille": "cm", "tour_bras": "cm", "tour_avant_bras": "cm",
          "tour_cuisse": "cm", "tour_poitrine": "cm", "test_course": "s",
          "test_force": "reps"}
SITUATIONS = {"esquisse": "esquisse", "proposee": "à valider", "validee": "validée",
              "faite": "faite", "pas_faite": "pas faite", "remplacee": "remplacée",
              "retiree": "retirée", "posee_a_la_main": "posée à la main"}


def h(texte) -> str:
    """Le bot envoie en HTML : tout texte variable est échappé, sans toucher aux
    apostrophes, que Telegram afficherait telles quelles."""
    return html.escape(str(texte if texte is not None else ""), quote=False)


def _couper(texte: str) -> str:
    if len(texte) <= MAX_TEXTE:
        return texte
    return texte[:MAX_TEXTE].rsplit("\n", 1)[0] + "\n… (la suite se lit dans les échanges)"


def _qui(id_utilisateur: int) -> Appelant:
    ligne = un_seul("SELECT id_utilisateur, pseudo, role FROM utilisateur "
                    "WHERE id_utilisateur = %(u)s", {"u": id_utilisateur})
    return Appelant(**ligne)


def a_le_coach(id_utilisateur: int) -> bool:
    ligne = un_seul("SELECT coach_actif FROM utilisateur WHERE id_utilisateur = %(u)s",
                    {"u": id_utilisateur})
    return bool(ligne and ligne["coach_actif"])


def message_d_erreur(erreur: Exception) -> str:
    refus = refus_coach(erreur) if isinstance(erreur, psycopg.Error) else None
    if refus is not None:
        return refus["message"]
    detail = getattr(erreur, "detail", None)
    if isinstance(detail, dict) and detail.get("message"):
        return detail["message"]
    diag = getattr(erreur, "diag", None)
    if diag is not None and diag.message_primary:
        return diag.message_primary
    return "Impossible pour l'instant."


# ---------------------------------------------------------------------------
# Lire ce qu'on tape
# ---------------------------------------------------------------------------

def lire_jour(mot: str) -> date | None:
    """« 08/10 », « 08/10/2026 », « 2026-10-08 », « demain », « aujourd'hui »."""
    mot = mot.strip().lower()
    jour = aujourd_hui()
    if mot in ("aujourd'hui", "aujourdhui", "auj"):
        return jour
    if mot == "demain":
        return jour + timedelta(days=1)
    try:
        return date.fromisoformat(mot)
    except ValueError:
        pass
    trouve = re.fullmatch(r"(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?", mot)
    if not trouve:
        return None
    annee = int(trouve.group(3)) if trouve.group(3) else jour.year
    if annee < 100:
        annee += 2000
    try:
        lu = date(annee, int(trouve.group(2)), int(trouve.group(1)))
    except ValueError:
        return None
    # Sans année, une date déjà passée désigne l'an prochain.
    if not trouve.group(3) and lu < jour - timedelta(days=60):
        lu = lu.replace(year=annee + 1)
    return lu


def lire_heure(mot: str) -> time | None:
    """« 18h », « 18h30 », « 18:30 »."""
    trouve = re.fullmatch(r"(\d{1,2})\s*[h:]\s*(\d{2})?", mot.strip().lower())
    if not trouve:
        return None
    try:
        return time(int(trouve.group(1)), int(trouve.group(2) or 0))
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Une réponse du coach
# ---------------------------------------------------------------------------

def _jour_court(valeur) -> str:
    if isinstance(valeur, str):
        try:
            valeur = date.fromisoformat(valeur[:10])
        except ValueError:
            return valeur
    return f"{jour_en_clair(valeur)}"


def boutons_des_elements(elements: list[dict]) -> list[list[tuple[str, str]]]:
    """COA-19 : un bloc de boutons par élément. Un type inconnu est ignoré."""
    rangees: list[list[tuple[str, str]]] = []
    for e in elements or []:
        genre = e.get("type")
        if genre == "seance_proposee":
            nom = f"{_jour_court(e.get('jour'))} · {e.get('type_seance', 'séance')}"
            rangees.append([(f"👁 {nom}"[:48], f"co:voir:{e['id_occurrence']}")])
        elif genre == "semaine_a_valider":
            lundi = str(e.get("lundi", ""))[:10].replace("-", "")
            rangees.append([(f"✅ Valider la semaine ({e.get('seances', '?')} séances)",
                             f"co:sem:{lundi}")])
        elif genre == "ajustement":
            a = e["id_ajustement"]
            rangees.append([("✅ Accepter l'ajustement", f"co:aja:{a}"),
                            ("Refuser", f"co:ajr:{a}")])
        elif genre == "fenetre_mesure":
            rangees.append([(f"Reporter la mesure ({e.get('type_mesure')})",
                             f"co:fen:{e['id_fenetre']}")])
        elif genre == "plan":
            rangees.append([("📋 Voir le plan", "co:plan:0")])
    return rangees[:12]


def ecran_reponse(rendu: dict) -> Ecran:
    """Le message du coach, puis ses boutons."""
    texte = h(rendu.get("message") or "")
    for cle, titre in (("plan_en_attente_de", "Le plan attend encore"),):
        if rendu.get(cle):
            texte += f"\n\n<b>{titre}</b> : " + h(" ; ".join(rendu[cle]))
    if rendu.get("plan_en_construction"):
        texte += "\n\n<i>Je construis ton plan. Il arrive par message dans quelques minutes.</i>"
    return Ecran(_couper(texte), boutons_des_elements(rendu.get("elements") or []))


def boutons_de_l_echange(id_echange: int | None) -> list[list[tuple[str, str]]]:
    if not id_echange:
        return []
    ligne = un_seul("SELECT elements FROM echange WHERE id_echange = %(e)s",
                    {"e": id_echange})
    return boutons_des_elements((ligne or {}).get("elements") or [])


def _demander(id_utilisateur: int, moment: str, texte: str | None,
              id_occurrence: int | None = None, precision: str | None = None) -> Ecran:
    rendu = appel.appeler_coach(appel.Demande(
        id_utilisateur=id_utilisateur, moment=moment, declencheur="utilisateur",
        texte=texte, id_occurrence=id_occurrence, precision=precision,
        cle_client=str(uuid.uuid4()), deja_affichee=True))
    return ecran_reponse(rendu)


def texte_libre(id_utilisateur: int, texte: str) -> Ecran | None:
    """Un texte sans commande est une question pour le coach (section 9.4).

    Si c'est en fait un signalement, le coach le requalifie lui-même : on n'a
    pas à choisir la bonne commande pour être pris au sérieux. Pour un compte
    sans coach, le bot se tait comme avant.
    """
    if not a_le_coach(id_utilisateur) or not texte.strip():
        return None
    return _demander(id_utilisateur, "chat", texte.strip())


# ---------------------------------------------------------------------------
# Écrans
# ---------------------------------------------------------------------------

def _ligne_seance(s: dict) -> str:
    heure = f"{s['debut'][11:]} " if s.get("debut") else ""
    nom = s.get("type_seance") or "séance"
    discipline = s.get("discipline") or "sport"
    etat = SITUATIONS.get(s.get("situation"), s.get("situation") or "")
    details = [f"{s['duree_minutes']} min"] if s.get("duree_minutes") else []
    if s.get("intensite"):
        details.append(s["intensite"])
    if s.get("cle"):
        details.append("clé")
    if s.get("effort"):
        details.append(f"effort {s['effort']}")
    return (f"• <b>{h(_jour_court(s['jour']))}</b> {h(heure)}{h(discipline)} : {h(nom)} "
            f"({h(', '.join(details))}) · <i>{h(etat)}</i>")


def ecran_semaine(id_utilisateur: int, lundi: date | None = None) -> Ecran:
    if lundi is None:
        # La première semaine qui a des séances à valider, sinon la semaine en cours.
        ligne = un_seul(
            "SELECT min(lundi) AS lundi FROM v_seance_coach WHERE id_utilisateur = %(u)s "
            "AND situation IN ('proposee', 'esquisse') AND lundi >= lundi_de(jour_de(now()))",
            {"u": id_utilisateur})
        lundi = (ligne or {}).get("lundi") or lundi_de(aujourd_hui())
    semaine = outils.lire_semaine(id_utilisateur, {"lundi": lundi.isoformat()})
    lignes = [f"<b>Semaine du {lundi:%d/%m}</b>"]
    plan = semaine["semaine_du_plan"]
    if isinstance(plan, dict):
        lignes.append(f"Rôle : {h(plan.get('role'))}"
                      + (f". {h(plan['intention'])}" if plan.get("intention") else ""))
    if not semaine["seances"]:
        lignes.append("Aucune séance cette semaine.")
    boutons: list[list[tuple[str, str]]] = []
    a_valider = esquisses = 0
    for s in semaine["seances"]:
        lignes.append(_ligne_seance(s))
        if s.get("situation") in ("proposee", "esquisse", "validee", "posee_a_la_main"):
            boutons.append([(f"👁 {_jour_court(s['jour'])} · "
                             f"{s.get('type_seance') or 'séance'}"[:48],
                             f"co:voir:{s['id_occurrence']}")])
        a_valider += s.get("situation") == "proposee"
        esquisses += s.get("situation") == "esquisse"
    if esquisses:
        lignes.append(f"\n{esquisses} séance(s) ne sont encore que des esquisses : le coach "
                      "les détaille à la révision du dimanche.")
    elif a_valider:
        boutons.insert(0, [(f"✅ Valider la semaine ({a_valider} séances)",
                            f"co:sem:{lundi:%Y%m%d}")])
    boutons.append([("◀ Semaine précédente", f"co:semv:{lundi - timedelta(days=7):%Y%m%d}"),
                    ("Semaine suivante ▶", f"co:semv:{lundi + timedelta(days=7):%Y%m%d}")])
    return Ecran("\n".join(lignes), boutons[:14])


def _exercice_en_clair(p: dict) -> str:
    morceaux = []
    if p.get("series") and (p.get("repetitions_min") or p.get("repetitions_max")):
        mini, maxi = p.get("repetitions_min"), p.get("repetitions_max")
        reps = f"{mini}-{maxi}" if mini and maxi and mini != maxi else f"{maxi or mini}"
        morceaux.append(f"{p['series']} × {reps}")
    elif p.get("series", 1) > 1:
        morceaux.append(f"{p['series']} ×")
    if p.get("charge_kg") is not None:
        morceaux.append(f"{p['charge_kg']} kg")
    if p.get("duree_secondes"):
        d = p["duree_secondes"]
        morceaux.append(f"{d // 60} min" if d % 60 == 0 else f"{d} s")
    if p.get("distance_m"):
        morceaux.append(f"{p['distance_m']} m")
    if p.get("cible"):
        morceaux.append(p["cible"])
    if p.get("marge_repetitions") is not None:
        morceaux.append(f"{p['marge_repetitions']} en réserve")
    if p.get("repos_secondes"):
        morceaux.append(f"repos {p['repos_secondes']} s")
    ligne = f"{p['rang']}. <b>{h(p['libelle'])}</b> : {h(', '.join(morceaux))}"
    ligne += f"\n    <code>{h(p['code'])}</code>"
    if p.get("consigne"):
        ligne += f" {h(p['consigne'])}"
    return ligne


def ecran_seance(id_utilisateur: int, id_occurrence: int) -> Ecran:
    detail = outils.detail_seance(id_utilisateur, id_occurrence)
    if detail is None:
        return Ecran("Cette séance n'existe plus.")
    s = detail["seance"]
    lignes = [_ligne_seance(s).lstrip("• ")]
    if s.get("lieu"):
        lignes.append(f"Lieu : {h(s['lieu'])}")
    if s.get("consigne"):
        lignes.append(h(s["consigne"]))
    if detail["prevu"]:
        lignes.append("")
        lignes += [_exercice_en_clair(p) for p in detail["prevu"]]
    elif s.get("situation") == "esquisse":
        lignes.append("Esquisse : le coach écrira les exercices à la révision du dimanche.")
    if detail["saisi"]:
        lignes.append("\n<b>Saisi</b>")
        for x in detail["saisi"]:
            valeur = " × ".join(str(v) for v in (
                f"{x['charge_kg']} kg" if x.get("charge_kg") is not None else None,
                x.get("repetitions")) if v is not None)
            if x.get("duree_secondes"):
                valeur = f"{x['duree_secondes']} s"
            if x.get("distance_m"):
                valeur = f"{x['distance_m']} m" + (f" en {x['duree_secondes']} s"
                                                   if x.get("duree_secondes") else "")
            lignes.append(f"• {h(x['libelle'])} n° {x['numero']} : {h(valeur)}")
    if detail["montre"]:
        m = detail["montre"][0]
        lignes.append(f"\nMontre : {h(m.get('type'))}, {m['duree_secondes'] // 60} min"
                      + (f", {m['distance_m']} m" if m.get("distance_m") else "")
                      + (f", FC moyenne {m['fc_moyenne']}" if m.get("fc_moyenne") else ""))

    o = id_occurrence
    ouverte = s.get("statut_occurrence") in ("a_placer", "planifiee", "notifiee")
    boutons: list[list[tuple[str, str]]] = []
    if ouverte and s.get("situation") == "proposee":
        boutons.append([("✅ Valider cette séance", f"co:val:{o}"),
                        ("🗑 Supprimer", f"co:sup:{o}")])
    if ouverte and s.get("situation") in ("validee", "proposee", "posee_a_la_main"):
        boutons.append([("Faite", f"co:fai:{o}"), ("Pas faite", f"co:pf:{o}")])
        if not s.get("libre"):
            boutons.append([("Faire autre chose", f"co:lib:{o}")])
        lignes.append("\nPour saisir une série : <code>/serie code charge reps</code>")
    if s.get("situation") == "faite":
        boutons.append([("💬 Bilan du coach", f"co:bil:{o}")])
        if not s.get("effort"):
            boutons.append([("Donner la note d'effort", f"co:fai:{o}")])
    return Ecran(_couper("\n".join(lignes)), boutons)


def ecran_effort(id_occurrence: int) -> Ecran:
    """SAI-14 : le bouton « faite » demande la note d'effort, d'un seul geste."""
    rangee1 = [(str(n), f"co:eff:{id_occurrence}_{n}") for n in range(1, 6)]
    rangee2 = [(str(n), f"co:eff:{id_occurrence}_{n}") for n in range(6, 11)]
    return Ecran("Quel effort, de 1 (très facile) à 10 (maximal) ?", [rangee1, rangee2])


def ecran_du_jour(id_utilisateur: int) -> Ecran:
    lignes = lister(
        "SELECT id_occurrence FROM v_seance_coach WHERE id_utilisateur = %(u)s "
        "AND jour = jour_de(now()) ORDER BY debut NULLS LAST", {"u": id_utilisateur})
    if not lignes:
        return Ecran("Pas de séance aujourd'hui. /semaine pour voir la suite, "
                     "/libre pour en ouvrir une.")
    if len(lignes) == 1:
        return ecran_seance(id_utilisateur, lignes[0]["id_occurrence"])
    semaine = outils.lire_semaine(id_utilisateur, {})
    du_jour = [s for s in semaine["seances"] if s["jour"] == aujourd_hui().isoformat()]
    return Ecran("<b>Aujourd'hui</b>\n" + "\n".join(_ligne_seance(s) for s in du_jour),
                 [[(f"👁 {s.get('type_seance') or 'séance'}"[:48],
                    f"co:voir:{s['id_occurrence']}")] for s in du_jour])


def ecran_plan(id_utilisateur: int) -> Ecran:
    rendu = routes.lire_plan(_qui(id_utilisateur))
    lignes = []
    principal = rendu["objectif_principal"]
    lignes.append(f"<b>Objectif principal</b> : {h(principal['libelle'])}"
                  if principal else "Pas d'objectif principal. /objectifs pour en créer un.")
    if rendu["feuille_de_route"]:
        lignes.append(f"\n<b>Feuille de route</b>\n{h(rendu['feuille_de_route'])}")
    plan = rendu["plan"]
    if plan is None:
        lignes.append("\nAucun plan en cours.")
        if rendu["manque"]:
            lignes.append("Il manque : " + h(" ; ".join(rendu["manque"])))
        else:
            lignes.append("Envoie <code>/plan nouveau</code> pour que le coach le construise.")
    else:
        lignes.append(f"\n<b>Plan du {plan['du']:%d/%m} au {plan['au']:%d/%m}</b>\n"
                      f"{h(plan['trame'])}")
        for s in plan["semaines"]:
            etat = "validée" if s["validee_le"] else "à valider"
            lignes.append(f"• {s['lundi']:%d/%m} : {h(s['role'])} ({etat})"
                          + (f". {h(s['intention'])}" if s["intention"] else ""))
    if rendu["pause"]:
        lignes.append("\n⏸ Le coach est en pause. /pause pour la lever.")
    return Ecran(_couper("\n".join(lignes)), [[("📅 La semaine", "co:semv:0")]])


def ecran_objectifs(id_utilisateur: int) -> Ecran:
    objectifs = [o for o in contexte.objectifs(id_utilisateur)
                 if o["statut"] in ("actif", "en_pause")]
    lignes = ["<b>Mes objectifs</b>"]
    boutons: list[list[tuple[str, str]]] = []
    for o in objectifs:
        marque = "★ " if o["principal"] else ""
        etat = " (en pause)" if o["statut"] == "en_pause" else ""
        echeance = f", pour le {o['echeance']:%d/%m/%Y}" if o["echeance"] else ""
        avis = f"\n   Avis du coach : {h(o['avis'])}. {h(o['avis_detail'] or '')}" \
            if o["avis"] else ""
        lignes.append(f"• {marque}<b>{h(o['libelle'])}</b>{etat}{echeance}{avis}")
        i = o["id_objectif"]
        rangee = []
        if not o["principal"] and o["statut"] == "actif":
            rangee.append(("★ Principal", f"co:obp:{i}"))
        rangee.append(("▶ Reprendre", f"co:obr:{i}") if o["statut"] == "en_pause"
                      else ("⏸ Pause", f"co:obs:{i}"))
        rangee += [("✔ Atteint", f"co:oba:{i}"), ("✖ Abandon", f"co:obx:{i}")]
        boutons.append([(f"{h(o['libelle'])[:30]} :", "co:rien:0")])
        boutons.append(rangee)
    if not objectifs:
        lignes.append("Aucun objectif pour l'instant.")
    lignes.append(
        "\nPour en ajouter un :\n"
        "<code>/objectifs pilier force|physique|endurance Libellé</code>\n"
        "<code>/objectifs course 10000 12/04/2027 Semi de Nancy</code> (distance en mètres)\n"
        "<code>/objectifs mesure tour_bras 38 cm Libellé</code>\n"
        "Le premier créé devient le principal.")
    return Ecran("\n".join(lignes), boutons[:14])


def ecran_profil(id_utilisateur: int) -> Ecran:
    p = contexte.profil(id_utilisateur)
    d = contexte.depistage(id_utilisateur)
    lignes = ["<b>Mon profil</b>"]
    if p is None:
        lignes.append("Pas encore rempli.")
    else:
        lignes.append(f"{p['age']} ans, {h(p['sexe'])}, {p['taille_cm']} cm. Musculation : "
                      f"{h(p['niveau_musculation'])}. Course : {h(p['niveau_course'])}. "
                      f"Moment préféré : {h(p['moment_prefere'])}.")
    lignes.append("\nPour le remplir ou le changer :\n"
                  "<code>/profil AAAA-MM-JJ homme|femme taille_cm niveau_muscu niveau_course "
                  "matin|soir|indifferent</code>\n"
                  "Les niveaux : debutant, intermediaire, avance.")
    lignes.append("\n<b>Dépistage</b>")
    if d is None:
        lignes.append("Pas encore rempli.")
    else:
        lignes.append(f"Rempli le {d['date_reponse']:%d/%m/%Y}. "
                      + h(d["bloque"] or "Il ne bloque rien."))
    lignes.append("Sept questions, à répondre par oui ou non, dans l'ordre :")
    for rang, question in enumerate(routes.QUESTIONS_DEPISTAGE.values(), 1):
        lignes.append(f"{rang}. {h(question)}")
    lignes.append("\nRéponds par sept lettres, o pour oui et n pour non :\n"
                  "<code>/profil depistage nnnnnnn</code>\n"
                  "Après un avis médical : <code>/profil avis AAAA-MM-JJ</code>")
    manques = contexte.ce_qui_manque(id_utilisateur)
    if manques:
        lignes.append("\n<b>Avant un premier plan, il manque</b> : " + h(" ; ".join(manques)))
    return Ecran("\n".join(lignes))


def ecran_lieux(id_utilisateur: int) -> Ecran:
    rendu = routes.lire_lieux(_qui(id_utilisateur))
    lignes = ["<b>Mes lieux par discipline</b>"]
    for discipline in ("musculation", "course", "cardio"):
        choisis = [f"{c['libelle']} ({c['id_lieu']})" for c in rendu["choisis"]
                   if c["discipline"] == discipline]
        lignes.append(f"• {discipline} : {h(', '.join(choisis) or 'aucun')}")
    lignes.append("\nLieux connus : " + h(", ".join(
        f"{p['libelle']} = {p['id_lieu']}" for p in rendu["possibles"])))
    lignes.append("\nPour choisir, dans l'ordre de préférence :\n"
                  "<code>/lieux musculation 2</code>\n<code>/lieux course 7 2</code>")
    return Ecran("\n".join(lignes))


def ecran_coach(id_utilisateur: int) -> Ecran:
    r = contexte.reglages(id_utilisateur)
    lignes = [f"Coach : <b>{'activé' if r.get('coach_actif') else 'coupé'}</b>"]
    manques = contexte.ce_qui_manque(id_utilisateur)
    if manques:
        lignes.append("Il manque : " + h(" ; ".join(manques)))
    cout = lister(
        """SELECT moment, sum(appels) AS appels, sum(echecs) AS echecs,
                  sum(tokens_entree) AS entree, sum(tokens_cache) AS cache,
                  sum(tokens_sortie) AS sortie
             FROM v_cout_coach WHERE id_utilisateur = %(u)s AND jour > jour_de(now()) - 7
            GROUP BY moment ORDER BY moment""", {"u": id_utilisateur})
    if cout:
        lignes.append("\n<b>Sept derniers jours</b>")
        for c in cout:
            lignes.append(f"• {c['moment']} : {c['appels']} appel(s), {c['echecs']} échec(s), "
                          f"{c['entree']} tokens lus dont {c['cache']} du cache, "
                          f"{c['sortie']} écrits")
    lignes.append("\n<code>/coach on</code> ou <code>/coach off</code> (administrateur). "
                  "<code>/coach synthese</code> déclenche la synthèse du soir maintenant.")
    return Ecran("\n".join(lignes))


# ---------------------------------------------------------------------------
# Commandes
# ---------------------------------------------------------------------------

def _seance_du_jour(id_utilisateur: int, ouverte: bool | None = None) -> int | None:
    ligne = un_seul(
        """SELECT id_occurrence FROM v_seance_coach
            WHERE id_utilisateur = %(u)s AND jour = jour_de(now()) AND discipline IS NOT NULL
              AND (%(o)s::BOOLEAN IS NULL
                   OR (statut_occurrence IN ('a_placer', 'planifiee', 'notifiee')) = %(o)s)
            ORDER BY (situation = 'faite'), debut NULLS LAST LIMIT 1""",
        {"u": id_utilisateur, "o": ouverte})
    return ligne["id_occurrence"] if ligne else None


def _objectifs(id_utilisateur: int, args: list[str]) -> Ecran:
    if not args:
        return ecran_objectifs(id_utilisateur)
    genre = args[0].lower()
    premier = not any(o["principal"] and o["statut"] == "actif"
                      for o in contexte.objectifs(id_utilisateur))
    try:
        if genre == "pilier" and len(args) >= 2:
            nouveau = routes.NouvelObjectif(
                type="pilier", pilier=args[1].lower(),
                libelle=" ".join(args[2:]) or f"Pilier {args[1].lower()}", principal=premier)
        elif genre == "course" and len(args) >= 3:
            echeance = lire_jour(args[2])
            if echeance is None:
                return Ecran("Je n'ai pas compris la date. Exemple : 12/04/2027")
            nouveau = routes.NouvelObjectif(
                type="course", distance_m=int(args[1]), echeance=echeance,
                libelle=" ".join(args[3:]) or f"Course de {int(args[1]) / 1000:g} km",
                principal=premier)
        elif genre == "mesure" and len(args) >= 4:
            nouveau = routes.NouvelObjectif(
                type="mesure", type_mesure=args[1].lower(),
                cible_valeur=float(args[2].replace(",", ".")), cible_unite=args[3],
                libelle=" ".join(args[4:]) or f"{args[1]} à {args[2]} {args[3]}",
                principal=premier)
        else:
            return ecran_objectifs(id_utilisateur)
    except ValueError as erreur:
        return Ecran(f"Objectif refusé : {h(erreur)}")
    rendu = routes.creer_objectif(_qui(id_utilisateur), nouveau)
    if rendu["coach"]:
        return ecran_reponse(rendu["coach"])
    return Ecran(f"Objectif créé : {h(rendu['objectif']['libelle'])}.")


def _profil(id_utilisateur: int, args: list[str]) -> Ecran:
    qui = _qui(id_utilisateur)
    if args and args[0].lower() == "depistage" and len(args) >= 2:
        lettres = args[1].lower()
        if len(lettres) != 7 or set(lettres) - set("on"):
            return Ecran("Il faut sept lettres, o pour oui et n pour non. "
                         "Exemple : /profil depistage nnnnnnn")
        reponses = dict(zip(routes.QUESTIONS_DEPISTAGE, (c == "o" for c in lettres),
                            strict=True))
        etat = routes.repondre_depistage(qui, routes.Depistage(**reponses))["dernier"]
        return Ecran("Dépistage enregistré. " + h(etat["bloque"] or "Il ne bloque rien."))
    if args and args[0].lower() == "avis" and len(args) >= 2:
        jour = lire_jour(args[1])
        if jour is None:
            return Ecran("Je n'ai pas compris la date de l'avis médical.")
        routes.repondre_depistage(qui, routes.Depistage(avis_medical_le=jour))
        return Ecran("Avis médical noté. Le plan n'est plus bloqué par le dépistage.")
    if len(args) >= 5:
        naissance = lire_jour(args[0])
        if naissance is None:
            return Ecran("Je n'ai pas compris la date de naissance (AAAA-MM-JJ).")
        try:
            profil = routes.Profil(
                date_naissance=naissance, sexe=args[1].lower(), taille_cm=int(args[2]),
                niveau_musculation=args[3].lower(), niveau_course=args[4].lower(),
                moment_prefere=args[5].lower() if len(args) > 5 else "indifferent")
        except ValueError as erreur:
            return Ecran(f"Profil refusé : {h(str(erreur)[:300])}")
        routes.ecrire_profil(qui, profil)
    return ecran_profil(id_utilisateur)


def _lieux(id_utilisateur: int, args: list[str]) -> Ecran:
    if len(args) >= 2 and args[0].lower() in DISCIPLINES:
        try:
            choisis = [int(a) for a in args[1:]]
        except ValueError:
            return Ecran("Donne les numéros des lieux. Exemple : /lieux course 7 2")
        routes.choisir_lieux(_qui(id_utilisateur), DISCIPLINES[args[0].lower()], choisis)
    return ecran_lieux(id_utilisateur)


def _plan(id_utilisateur: int, args: list[str]) -> Ecran:
    if args and args[0].lower() in ("nouveau", "reconstruire"):
        rendu = routes.reconstruire_plan(_qui(id_utilisateur))
        return Ecran(h(rendu["message"]))
    return ecran_plan(id_utilisateur)


def _bilan(id_utilisateur: int, args: list[str]) -> Ecran:
    seance = _seance_du_jour(id_utilisateur)
    if seance is None:
        return Ecran("Pas de séance aujourd'hui. /libre pour en saisir une.")
    effort = None
    if args and args[0].isdigit() and 1 <= int(args[0]) <= 10:
        effort, args = int(args[0]), args[1:]
    texte = " ".join(args).strip() or None
    deja = un_seul("SELECT 1 FROM bilan_seance WHERE id_occurrence = %(o)s", {"o": seance})
    if deja is None and effort is None:
        ecran = ecran_effort(seance)
        ecran.texte = ("Donne d'abord ta note d'effort, puis renvoie /bilan avec ton "
                       "commentaire.\n" + ecran.texte)
        return ecran
    if deja is None:
        routes.enregistrer_bilan(_qui(id_utilisateur), seance,
                                 routes.Bilan(effort=effort, commentaire=texte))
    return _demander(id_utilisateur, "bilan", texte, seance)


def _signaler(id_utilisateur: int, args: list[str]) -> Ecran:
    texte = " ".join(args).strip()
    if not texte:
        return Ecran("Écris ce que tu veux signaler après la commande. "
                     "Exemple : /signaler gêne au coude gauche depuis ce matin, 3 sur 10")
    return _demander(id_utilisateur, "signalement", texte)


def _libre(id_utilisateur: int, args: list[str]) -> Ecran:
    discipline = next((DISCIPLINES[a.lower()] for a in args if a.lower() in DISCIPLINES), None)
    if discipline is None:
        return Ecran("Dis la discipline : musculation, course ou cardio.\n"
                     "<code>/libre musculation</code> ouvre une séance maintenant.\n"
                     "<code>/libre 08/10 18h course</code> en annonce une.")
    jour = next((lire_jour(a) for a in args if lire_jour(a)), None)
    heure = next((lire_heure(a) for a in args if lire_heure(a)), None)
    reste = " ".join(a for a in args if a.lower() not in DISCIPLINES
                     and not lire_jour(a) and not lire_heure(a)).strip() or None
    qui = _qui(id_utilisateur)
    if jour is None and heure is None:
        detail = routes.ouvrir_seance_libre(qui, routes.SeanceLibre(
            discipline=discipline, cle_client=uuid.uuid4()))
        return ecran_seance(id_utilisateur, detail["seance"]["id_occurrence"])
    debut = datetime.combine(jour or aujourd_hui(), heure or time(18, 0), tzinfo=fuseau())
    if debut <= maintenant():
        detail = routes.ouvrir_seance_libre(qui, routes.SeanceLibre(
            discipline=discipline, debut=debut, cle_client=uuid.uuid4()))
        return ecran_seance(id_utilisateur, detail["seance"]["id_occurrence"])
    rendu = routes.annoncer_seance_libre(qui, routes.SeanceLibre(
        discipline=discipline, debut=debut, texte=reste, cle_client=uuid.uuid4()))
    return ecran_reponse(rendu["coach"])


def _mesure(id_utilisateur: int, args: list[str]) -> Ecran:
    if len(args) < 2 or args[0].lower() not in UNITES:
        ouvertes = routes.fenetres_ouvertes(_qui(id_utilisateur))
        lignes = ["<code>/mesure type valeur [gauche|droite]</code>",
                  "Types : " + ", ".join(UNITES)]
        for f in ouvertes:
            lignes.append(f"• Attendue : {h(f['type_mesure'])} du {f['du']:%d/%m} au "
                          f"{f['au']:%d/%m}. {h(f['consigne'] or '')}")
        return Ecran("\n".join(lignes))
    try:
        valeur = float(args[1].replace(",", "."))
    except ValueError:
        return Ecran("Je n'ai pas compris la valeur.")
    cote = next((a.lower() for a in args[2:] if a.lower() in ("gauche", "droite")), None)
    genre = args[0].lower()
    routes.saisir_mesure(_qui(id_utilisateur), routes.Mesure(
        type=genre, valeur=valeur, unite=UNITES[genre], cote=cote))
    return Ecran(f"Noté : {h(genre)} {valeur:g} {UNITES[genre]}"
                 + (f" ({cote})" if cote else "") + ".")


def _pause(id_utilisateur: int, args: list[str]) -> Ecran:
    qui = _qui(id_utilisateur)
    if not args and contexte.pause(id_utilisateur):
        return Ecran(h(routes.lever_pause(qui)["message"]))
    fin = lire_jour(args[0]) if args else None
    motif = " ".join(args[1:] if fin else args).strip() or None
    pause = routes.mettre_en_pause(qui, routes.Pause(motif=motif, fin=fin))["pause"]
    jusqu = f"jusqu'au {pause['jusqu_au']:%d/%m}" if pause and pause["jusqu_au"] \
        else "sans date de fin"
    return Ecran(f"Coach en pause, {jusqu}. Il ne propose plus rien, et la synthèse ne "
                 "passe qu'un soir sur trois. /pause pour la lever.")


def _serie(id_utilisateur: int, args: list[str]) -> Ecran:
    """Saisir une série depuis le bot : `/serie code 40 10`, `/serie planche 60s`."""
    if len(args) < 2:
        return Ecran("<code>/serie code charge reps</code> (musculation)\n"
                     "<code>/serie code 90s</code> (durée) ou <code>/serie code 1000m</code> "
                     "(distance)\nLes codes sont affichés dans /seance.")
    seance = _seance_du_jour(id_utilisateur, True) or _seance_du_jour(id_utilisateur)
    if seance is None:
        return Ecran("Pas de séance aujourd'hui. /libre pour en ouvrir une.")
    serie = {"code": args[0].lower(), "cle_client": uuid.uuid4()}
    for mot in args[1:]:
        mot = mot.lower().replace(",", ".")
        if re.fullmatch(r"\d+(\.\d+)?s", mot):
            serie["duree_secondes"] = int(float(mot[:-1]))
        elif re.fullmatch(r"\d+min", mot):
            serie["duree_secondes"] = int(mot[:-3]) * 60
        elif re.fullmatch(r"\d+(\.\d+)?km", mot):
            serie["distance_m"] = int(float(mot[:-2]) * 1000)
        elif re.fullmatch(r"\d+m", mot):
            serie["distance_m"] = int(mot[:-1])
        elif re.fullmatch(r"\d+(\.\d+)?(kg)?", mot) and "charge_kg" not in serie \
                and "repetitions" not in serie and len(args) > 2:
            serie["charge_kg"] = float(mot.removesuffix("kg"))
        elif mot.isdigit():
            serie["repetitions"] = int(mot)
    rendu = routes.enregistrer_series(_qui(id_utilisateur), seance,
                                      routes.Serie(**serie))["series"][0]
    if rendu["etat"] == "refusee":
        return Ecran(f"Série refusée : {h(rendu['message'])}")
    return Ecran(f"Série n° {rendu.get('numero', '?')} enregistrée sur "
                 f"<code>{h(serie['code'])}</code>.")


def _coach(id_utilisateur: int, args: list[str]) -> Ecran:
    qui = _qui(id_utilisateur)
    if args and args[0].lower() in ("on", "off"):
        if not qui.est_admin:
            return Ecran("Réservé à l'administrateur.")
        routes.activer_coach(qui, None, args[0].lower() == "on")
    elif args and args[0].lower() == "synthese":
        if not qui.est_admin:
            return Ecran("Réservé à l'administrateur.")
        cloture = planifie.clore_le_jour(id_utilisateur)
        rendu = appel.appeler_coach(appel.Demande(
            id_utilisateur=id_utilisateur, moment="synthese", declencheur="utilisateur",
            precision=planifie._precision(cloture) or None, deja_affichee=True))
        planifie.figer(id_utilisateur)
        return ecran_reponse(rendu)
    return ecran_coach(id_utilisateur)


COMMANDES = {
    "objectifs": _objectifs,
    "profil": _profil,
    "semaine": lambda u, a: ecran_semaine(
        u, lundi_de(aujourd_hui()) + timedelta(days=7) if a and a[0].startswith("proch")
        else None),
    "seance": lambda u, a: ecran_du_jour(u),
    "bilan": _bilan,
    "signaler": _signaler,
    "libre": _libre,
    "mesure": _mesure,
    "plan": _plan,
    "lieux": _lieux,
    "pause": _pause,
    "serie": _serie,
    "coach": _coach,
}

# Ces commandes servent à démarrer : elles marchent avant que le coach soit activé.
SANS_COACH = {"profil", "lieux", "coach", "objectifs"}


def commande(nom: str, id_utilisateur: int, args: list[str]) -> Ecran:
    if nom not in SANS_COACH and not a_le_coach(id_utilisateur):
        return Ecran("Le coach n'est pas activé pour ton compte.")
    try:
        return COMMANDES[nom](id_utilisateur, args)
    except appel.CoachInactif:
        return Ecran("Le coach n'est pas activé pour ton compte.")
    except Exception as erreur:  # noqa: BLE001 - une commande ne doit jamais rester muette
        return Ecran(h(message_d_erreur(erreur)))


# ---------------------------------------------------------------------------
# Boutons
# ---------------------------------------------------------------------------

def est_seance_du_coach(id_occurrence: int) -> bool:
    """SAI-14 : pour un compte qui a le coach, « faite » demande la note d'effort."""
    return un_seul(
        """SELECT 1 FROM seance s JOIN occurrence o ON o.id_occurrence = s.id_occurrence
             JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
            WHERE s.id_occurrence = %(o)s AND u.coach_actif""",
        {"o": id_occurrence}) is not None


def _lundi(texte: str) -> date | None:
    try:
        return datetime.strptime(texte, "%Y%m%d").date()
    except ValueError:
        return None


def repondre(id_utilisateur: int, action: str, argument: str) -> Ecran | None:
    """Un bouton. Rend l'écran qui remplace le message, ou None pour ne rien changer."""
    qui = _qui(id_utilisateur)
    try:
        if action == "rien":
            return None
        if action == "voir":
            return ecran_seance(id_utilisateur, int(argument))
        if action == "semv":
            return ecran_semaine(id_utilisateur, _lundi(argument))
        if action == "sem":
            lundi = _lundi(argument)
            rendu = routes.valider_semaine(qui, lundi)
            ecran = ecran_semaine(id_utilisateur, lundi)
            ecran.texte = f"✅ {rendu['validees']} séance(s) validée(s).\n\n" + ecran.texte
            return ecran
        if action == "val":
            routes.valider_seance(qui, int(argument))
            return ecran_seance(id_utilisateur, int(argument))
        if action == "sup":
            routes.supprimer_seance(qui, int(argument))
            return Ecran("Séance supprimée. Elle n'est pas comptée comme manquée.")
        if action == "lib":
            routes.liberer_seance(qui, int(argument))
            ecran = ecran_seance(id_utilisateur, int(argument))
            ecran.texte = ("C'est maintenant une séance libre : fais ce que tu veux, et "
                           "saisis-le avec /serie.\n\n" + ecran.texte)
            return ecran
        if action == "fai":
            return ecran_effort(int(argument))
        if action == "eff":
            seance, effort = argument.split("_")
            routes.enregistrer_bilan(qui, int(seance), routes.Bilan(effort=int(effort)))
            return Ecran(f"Séance faite, effort {effort}. Elle compte dans ta charge.",
                         [[("💬 Bilan du coach maintenant", f"co:bil:{seance}")]])
        if action == "pf":
            routes.declarer_pas_faite(qui, int(argument))
            return Ecran("Séance notée pas faite. Le coach décide de la suite à la "
                         "synthèse de ce soir.")
        if action == "bil":
            return _demander(id_utilisateur, "bilan", None, int(argument))
        if action == "aja":
            routes.accepter_ajustement(qui, int(argument))
            return Ecran("Ajustement accepté : la séance est mise à jour.")
        if action == "ajr":
            routes.refuser_ajustement(qui, int(argument))
            return Ecran("Ajustement refusé : la séance reste telle que tu l'avais validée.")
        if action == "fen":
            routes.reporter_fenetre(qui, int(argument))
            return Ecran("Mesure reportée. Le coach en rouvrira une plus tard.")
        if action == "plan":
            return ecran_plan(id_utilisateur)
        if action == "obp":
            routes.designer_principal(qui, int(argument))
        elif action == "obs":
            routes.suspendre_objectif(qui, int(argument))
        elif action == "obr":
            routes.reprendre_objectif(qui, int(argument))
        elif action == "oba":
            routes.clore_objectif(qui, int(argument), True)
        elif action == "obx":
            routes.clore_objectif(qui, int(argument), False)
        else:
            return Ecran("Ce bouton n'est plus reconnu.")
        return ecran_objectifs(id_utilisateur)
    except appel.CoachInactif:
        return Ecran("Le coach n'est pas activé pour ton compte.")
    except Exception as erreur:  # noqa: BLE001 - un bouton ne doit jamais rester muet
        return Ecran(h(message_d_erreur(erreur)))
