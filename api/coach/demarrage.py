"""Le démarrage du coach dans le bot, question par question     (DEM-1 à DEM-4)

Tant que le profil, les lieux ou l'objectif principal manquent, le coach ne
peut rien construire (PRO-4, LIE-6, OBJ-8). Le bot conduit donc le compte pas
à pas, avec des boutons quand c'est possible, et refuse les commandes du coach
tant que ce n'est pas fini (DEM-1). Il demande aussi, une fois, s'il y a une
douleur ou une limitation qui dure (DEM-3).

Aucun questionnaire de santé ni avis médical : décision de l'utilisateur du 9
octobre. Rien ici ne porte une règle : chaque bloc fini passe par la route
habituelle (profil, limitation, lieux, objectif), et un refus de la base est
montré tel quel, la question reposée. Les réponses en cours vivent dans
`demarrage_coach`, qui garde aussi, une fois fini, que les limitations ont été
demandées.
"""

import html
from datetime import date

from psycopg.types.json import Jsonb

from api.base import executer, un_seul
from api.coach import contexte
from api.ecran import Ecran
from api.routeurs import coach as routes
from api.securite import Appelant

BLOCS = ("profil", "limitations", "lieux", "objectif")
TITRES = {"profil": "Ton profil", "limitations": "Douleurs et limitations",
          "lieux": "Tes lieux de sport", "objectif": "Ton objectif principal"}
ZONES = [("Épaule", "épaule"), ("Coude", "coude"), ("Avant-bras", "avant-bras"),
         ("Poignet", "poignet"), ("Dos", "dos"), ("Hanche", "hanche"),
         ("Genou", "genou"), ("Cheville", "cheville"), ("Autre", "autre")]
COTES = [("Gauche", "gauche"), ("Droite", "droite"), ("Les deux", "deux")]

NIVEAUX = [("Débutant", "debutant"), ("Intermédiaire", "intermediaire"),
           ("Avancé", "avance")]
JOURS = ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"]
DISCIPLINES = ("musculation", "course", "cardio")

# Les questions du profil, dans l'ordre : (clé, question, boutons ou None pour
# une réponse écrite).
QUESTIONS_PROFIL = [
    ("naissance", "Ta date de naissance ? Écris-la comme ceci : 14/03/2002.", None),
    ("sexe", "Ton sexe ?", [("Homme", "homme"), ("Femme", "femme")]),
    ("taille", "Ta taille, en centimètres ? Par exemple : 178.", None),
    ("niveau_musculation", "Ton niveau en musculation ?", NIVEAUX),
    ("niveau_course", "Ton niveau en course à pied ?", NIVEAUX),
    ("moment_prefere", "Quand préfères-tu t'entraîner ?",
     [("Le matin", "matin"), ("Le soir", "soir"), ("Peu importe", "indifferent")]),
    ("jours_sans_sport", "Les jours où tu ne veux jamais de sport ? Touche-les, puis "
                         "« Valider ». Aucun : « Valider » directement.", "jours"),
    ("accord_complements", "Veux-tu que le coach puisse te parler de compléments "
                           "alimentaires (protéines en poudre, créatine) ?",
     [("Oui", "1"), ("Non", "0")]),
    ("regime", "Un régime alimentaire à respecter (végétarien, sans porc…) ? "
               "Écris-le, ou touche « Aucun ».", [("Aucun", "-")]),
]
CLES_PROFIL = [q[0] for q in QUESTIONS_PROFIL]


def h(texte) -> str:
    return html.escape(str(texte if texte is not None else ""), quote=False)


def _qui(id_utilisateur: int) -> Appelant:
    ligne = un_seul("SELECT id_utilisateur, pseudo, role FROM utilisateur "
                    "WHERE id_utilisateur = %(u)s", {"u": id_utilisateur})
    return Appelant(**ligne)


# ---------------------------------------------------------------------------
# Où en est le compte
# ---------------------------------------------------------------------------

def bloc_manquant(id_utilisateur: int) -> str | None:
    """DEM-1 : le premier bloc qui manque, ou None si le démarrage est fini."""
    if contexte.profil(id_utilisateur) is None:
        return "profil"
    if not (_etat(id_utilisateur)["reponses"] or {}).get("_limitations_faites"):
        return "limitations"
    # DEM-7 : les adresses données, ou les lieux d'avant (ADR-18).
    deja = un_seul("SELECT 1 AS ok FROM discipline_lieu WHERE id_utilisateur = %(u)s LIMIT 1",
                   {"u": id_utilisateur})
    if not contexte.lieux(id_utilisateur) or (
            deja is None and not (_etat(id_utilisateur)["reponses"] or {}).get("_adresses_faites")):
        return "lieux"
    if not any(o["principal"] and o["statut"] == "actif"
               for o in contexte.objectifs(id_utilisateur)):
        return "objectif"
    return None


def requis(id_utilisateur: int) -> bool:
    return bloc_manquant(id_utilisateur) is not None


def _etat(id_utilisateur: int) -> dict:
    ligne = un_seul("SELECT etape, reponses FROM demarrage_coach WHERE id_utilisateur = %(u)s",
                    {"u": id_utilisateur})
    return ligne or {"etape": "", "reponses": {}}


def _garder(id_utilisateur: int, etape: str, reponses: dict) -> None:
    executer(
        """INSERT INTO demarrage_coach (id_utilisateur, etape, reponses)
           VALUES (%(u)s, %(e)s, %(r)s)
           ON CONFLICT (id_utilisateur) DO UPDATE
              SET etape = EXCLUDED.etape, reponses = EXCLUDED.reponses, maj = now()""",
        {"u": id_utilisateur, "e": etape, "r": Jsonb(reponses)})


def recommencer(id_utilisateur: int, avant: str = "") -> Ecran:
    executer("DELETE FROM demarrage_coach WHERE id_utilisateur = %(u)s", {"u": id_utilisateur})
    return ecran(id_utilisateur, avant)


# ---------------------------------------------------------------------------
# La question suivante
# ---------------------------------------------------------------------------

def _prochaine(id_utilisateur: int, reponses: dict) -> str | None:
    bloc = bloc_manquant(id_utilisateur)
    if bloc == "profil":
        return next(c for c in CLES_PROFIL + ["?"] if c not in reponses)
    if bloc == "limitations":
        if "lim_question" not in reponses:
            return "lim_question"
        return next(c for c in ("lim_zone", "lim_cote", "lim_texte", "lim_autre")
                    if c not in reponses)
    # Le bloc des lieux, une fois commencé, va au bout des trois disciplines :
    # un premier lieu choisi suffit à la base, pas au coach.
    if bloc == "lieux" or reponses.get("_bloc_lieux"):
        restantes = [d for d in DISCIPLINES if f"lieux_{d}" not in reponses]
        if restantes:
            return f"lieux_{restantes[0]}"
        if bloc == "lieux":
            return "lieux_aucun"
    if bloc == "objectif":
        if "objectif" not in reponses:
            return "objectif"
        if reponses["objectif"] == "course":
            return next((c for c in ("course_distance", "course_temps", "course_date")
                         if c not in reponses), "objectif")
        return "objectif"
    return None


def _entete(bloc: str) -> str:
    rang = BLOCS.index(bloc) + 1
    return f"<b>Démarrage du coach, étape {rang} sur 4 : {TITRES[bloc]}</b>\n\n"


def ecran(id_utilisateur: int, avant: str = "") -> Ecran:
    """La question en cours. `avant` : ce qu'il faut dire d'abord (un refus, un
    « c'est noté »)."""
    etat = _etat(id_utilisateur)
    reponses = etat["reponses"] or {}
    etape = _prochaine(id_utilisateur, reponses)
    if etape is None:
        # Le démarrage est fini. La ligne reste, pour se souvenir que les
        # limitations ont été demandées : /initialiser ou /reinitialiser l'effacent.
        _garder(id_utilisateur, "fini", {"_limitations_faites": True})
        return _fin(id_utilisateur, avant)
    _garder(id_utilisateur, etape, reponses)
    prefixe = (avant + "\n\n") if avant else ""

    if etape in CLES_PROFIL:
        cle, question, choix = next(q for q in QUESTIONS_PROFIL if q[0] == etape)
        rang = CLES_PROFIL.index(cle) + 1
        texte = prefixe + _entete("profil") + f"Question {rang} sur {len(CLES_PROFIL)}. " + \
            h(question)
        if choix == "jours":
            pris = set(reponses.get("_jours", []))
            ligne = [((("✅ " if i + 1 in pris else "") + nom), f"co:dm:j={i + 1}")
                     for i, nom in enumerate(JOURS)]
            return Ecran(texte, [ligne[:4], ligne[4:], [("Valider", "co:dm:jok=1")]])
        if choix:
            return Ecran(texte, [[(libelle, f"co:dm:{cle}={valeur}")
                                  for libelle, valeur in choix]])
        return Ecran(texte + "\n\n<i>Réponds par un message.</i>")

    if etape.startswith("lim_"):
        texte = prefixe + _entete("limitations")
        if etape == "lim_question":
            deja = contexte.limitations(id_utilisateur)
            if deja:
                texte += "Déjà notées : " + h(", ".join(lim["libelle"] for lim in deja)) + \
                    ".\n\n"
            texte += ("As-tu une douleur ou une limitation qui dure ? Une articulation "
                      "fragile, une ancienne blessure, un geste que tu ne peux pas faire. "
                      "Le coach en tiendra compte dans chaque séance.")
            return Ecran(texte, [[("Non", "co:dm:lim_question=0"),
                                  ("Oui", "co:dm:lim_question=1")]])
        if etape == "lim_zone":
            texte += "Où ?"
            return Ecran(texte, [[(n, f"co:dm:lim_zone={v}") for n, v in ZONES[i:i + 3]]
                                 for i in range(0, len(ZONES), 3)])
        if etape == "lim_cote":
            texte += "De quel côté ?"
            return Ecran(texte, [[(n, f"co:dm:lim_cote={v}") for n, v in COTES]])
        if etape == "lim_texte":
            texte += ("Décris-la en une ou deux phrases : ce qui fait mal, quand, et le geste "
                      "que tu ne peux pas faire. Par exemple : « je ne peux pas tourner "
                      "l'avant-bras paume vers le haut, les curls me font mal au coude ».")
            return Ecran(texte + "\n\n<i>Réponds par un message.</i>")
        texte += "Une autre ?"
        return Ecran(texte, [[("Non, c'est tout", "co:dm:lim_autre=0"),
                              ("Oui", "co:dm:lim_autre=1")]])

    if etape.startswith("lieux_"):
        discipline = etape[6:]
        possibles = routes.lire_lieux(_qui(id_utilisateur))["possibles"]
        if discipline == "aucun":
            # Toutes les disciplines ont été passées sans lieu : il en faut un.
            for d in DISCIPLINES:
                reponses.pop(f"lieux_{d}", None)
            _garder(id_utilisateur, "lieux_musculation", reponses)
            return ecran(id_utilisateur, "Il faut au moins un lieu pour une discipline, "
                                         "sinon le coach ne peut rien placer.")
        if not reponses.get("_bloc_lieux"):
            reponses["_bloc_lieux"] = True
            _garder(id_utilisateur, etape, reponses)
        pris = reponses.get("_lieux", [])
        texte = prefixe + _entete("lieux") + (
            f"Où fais-tu ta <b>{discipline}</b> ? Touche les lieux dans ton ordre de "
            "préférence, puis « Valider ». Si tu n'en fais pas, « Valider » directement.")
        if pris:
            noms = {p["id_lieu"]: p["libelle"] for p in possibles}
            texte += "\n\nChoisis : " + h(", ".join(noms.get(i, str(i)) for i in pris))
        boutons = [[(("✅ " if p["id_lieu"] in pris else "") + p["libelle"][:30],
                     f"co:dm:l={p['id_lieu']}")] for p in possibles[:10]]
        boutons.append([("Valider", "co:dm:lok=1")])
        return Ecran(texte, boutons)

    if etape == "objectif":
        texte = prefixe + _entete("objectif") + (
            "Quel est ton objectif principal ? Tu pourras en ajouter d'autres ensuite avec "
            "/objectifs.")
        return Ecran(texte, [
            [("💪 Prendre de la force", "co:dm:objectif=force")],
            [("🏋️ Prendre du muscle", "co:dm:objectif=physique")],
            [("🫀 Endurance et santé", "co:dm:objectif=endurance")],
            [("🏃 Préparer une course", "co:dm:objectif=course")],
        ])
    if etape == "course_distance":
        texte = prefixe + _entete("objectif") + (
            "Quelle distance ? Touche-la, ou écris-la en kilomètres (par exemple 15).")
        return Ecran(texte, [[("5 km", "co:dm:course_distance=5000"),
                              ("10 km", "co:dm:course_distance=10000")],
                             [("Semi", "co:dm:course_distance=21097"),
                              ("Marathon", "co:dm:course_distance=42195")]])
    if etape == "course_temps":
        return Ecran(prefixe + _entete("objectif") + (
            "En combien de temps veux-tu la courir ? Écris ton objectif, même s'il est "
            "ambitieux : par exemple <code>50 min</code> ou <code>1h45</code>."),
            [[("Juste la finir", "co:dm:course_temps=-")]])
    if etape == "course_date":
        return Ecran(prefixe + _entete("objectif")
                     + "La date de la course ? Écris-la comme ceci : 12/04/2027.")
    return Ecran(prefixe + "Je ne sais plus où on en était. /initialiser pour reprendre.")


def _fin(id_utilisateur: int, avant: str) -> Ecran:
    lignes = [avant] if avant else []
    lignes.append("<b>Le démarrage est fini.</b> Le coach a tout ce qu'il lui faut.")
    return Ecran("\n".join(lignes), [[("📋 Construire mon plan", "co:dm:plan=1")]])


# ---------------------------------------------------------------------------
# Les réponses
# ---------------------------------------------------------------------------

def _lire_date(texte: str) -> date | None:
    from api.coach.telegram import lire_jour
    return lire_jour(texte.strip())


def repondre_texte(id_utilisateur: int, texte: str) -> Ecran:
    """Une réponse écrite. Si la question attend un bouton, elle est reposée."""
    etat = _etat(id_utilisateur)
    reponses = etat["reponses"] or {}
    etape = _prochaine(id_utilisateur, reponses)
    texte = texte.strip()

    if etape == "naissance":
        jour = _lire_date(texte)
        if jour is None:
            return ecran(id_utilisateur, "Je n'ai pas compris la date. Exemple : 14/03/2002.")
        reponses["naissance"] = jour.isoformat()
    elif etape == "taille":
        try:
            taille = int(texte.lower().replace("cm", "").strip())
        except ValueError:
            return ecran(id_utilisateur, "Donne juste un nombre de centimètres, par exemple 178.")
        reponses["taille"] = taille
    elif etape == "regime":
        reponses["regime"] = texte[:200]
    elif etape == "course_distance":
        try:
            km = float(texte.lower().replace("km", "").replace(",", ".").strip())
        except ValueError:
            return ecran(id_utilisateur, "Donne la distance en kilomètres, par exemple 15.")
        reponses["course_distance"] = int(km * 1000)
    elif etape == "lim_texte":
        if len(texte) < 5:
            return ecran(id_utilisateur, "Décris-la en une phrase, s'il te plaît.")
        reponses["lim_texte"] = texte[:1000]
        cote = "des deux côtés" if reponses["lim_cote"] == "deux" else reponses["lim_cote"]
        try:
            routes.declarer_limitation(_qui(id_utilisateur), routes.Limitation(
                libelle=f"{reponses['lim_zone'].capitalize()} ({cote})",
                zone=reponses["lim_zone"], cote=reponses["lim_cote"],
                description=reponses["lim_texte"]))
        except Exception as erreur:  # noqa: BLE001 - montré, la question reposée
            return _refus(id_utilisateur, "limitations", reponses, erreur)
        _garder(id_utilisateur, etape, reponses)
        return ecran(id_utilisateur, "✅ Limitation notée.")
    elif etape == "course_temps":
        minutes = lire_duree(texte)
        if minutes is None:
            return ecran(id_utilisateur, "Je n'ai pas compris le temps. Exemple : 50 min, "
                                         "ou 1h45.")
        reponses["course_temps"] = minutes
    elif etape == "course_date":
        jour = _lire_date(texte)
        if jour is None:
            return ecran(id_utilisateur, "Je n'ai pas compris la date. Exemple : 12/04/2027.")
        reponses["course_date"] = jour.isoformat()
    else:
        return ecran(id_utilisateur, "Réponds avec les boutons, s'il te plaît.")
    _garder(id_utilisateur, etape or "", reponses)
    return _apres(id_utilisateur, reponses)


def repondre_bouton(id_utilisateur: int, argument: str) -> Ecran:
    """Un bouton `co:dm:cle=valeur`."""
    cle, _, valeur = argument.partition("=")
    if cle == "plan":
        rendu = routes.reconstruire_plan(_qui(id_utilisateur))
        return Ecran(h(rendu["message"]))
    if cle == "go":
        return ecran(id_utilisateur)
    reponses = _etat(id_utilisateur)["reponses"] or {}
    etape = _prochaine(id_utilisateur, reponses)

    if cle == "j" and etape == "jours_sans_sport":
        jours = set(reponses.get("_jours", []))
        jours ^= {int(valeur)}
        reponses["_jours"] = sorted(jours)
        _garder(id_utilisateur, etape, reponses)
        return ecran(id_utilisateur)
    if cle == "jok" and etape == "jours_sans_sport":
        reponses["jours_sans_sport"] = reponses.pop("_jours", [])
    elif cle == "l" and etape and etape.startswith("lieux_"):
        pris = reponses.get("_lieux", [])
        lieu = int(valeur)
        reponses["_lieux"] = [i for i in pris if i != lieu] if lieu in pris else pris + [lieu]
        _garder(id_utilisateur, etape, reponses)
        return ecran(id_utilisateur)
    elif cle == "lok" and etape and etape.startswith("lieux_"):
        choisis = reponses.pop("_lieux", [])
        reponses[etape] = choisis
        _garder(id_utilisateur, etape, reponses)
        if choisis:
            try:
                routes.choisir_lieux(_qui(id_utilisateur), etape[6:], choisis)
            except Exception as erreur:  # noqa: BLE001 - montré, la question reposée
                return _refus(id_utilisateur, "lieux", reponses, erreur)
            return ecran(id_utilisateur, f"✅ Lieux de {etape[6:]} enregistrés.")
        return ecran(id_utilisateur)
    elif cle == "lim_question" and etape == cle:
        if valeur == "0":
            return _limitations_finies(id_utilisateur, reponses)
        reponses[cle] = valeur
    elif cle == "lim_autre" and etape == cle:
        if valeur == "0":
            return _limitations_finies(id_utilisateur, reponses)
        for c in ("lim_zone", "lim_cote", "lim_texte", "lim_autre"):
            reponses.pop(c, None)
    elif cle == etape:
        reponses[cle] = valeur
    else:
        # Un vieux bouton, d'une question déjà répondue : on repose la bonne.
        return ecran(id_utilisateur)
    _garder(id_utilisateur, etape, reponses)
    return _apres(id_utilisateur, reponses)


def _apres(id_utilisateur: int, reponses: dict) -> Ecran:
    """Après une réponse : si un bloc est complet, il est enregistré."""
    qui = _qui(id_utilisateur)
    bloc = bloc_manquant(id_utilisateur)
    try:
        if bloc == "profil" and all(c in reponses for c in CLES_PROFIL):
            routes.ecrire_profil(qui, routes.Profil(
                date_naissance=date.fromisoformat(reponses["naissance"]),
                sexe=reponses["sexe"], taille_cm=int(reponses["taille"]),
                niveau_musculation=reponses["niveau_musculation"],
                niveau_course=reponses["niveau_course"],
                moment_prefere=reponses["moment_prefere"],
                jours_sans_sport=reponses["jours_sans_sport"],
                accord_complements=reponses["accord_complements"] == "1",
                regime=None if reponses["regime"] in ("-", "") else reponses["regime"]))
            return ecran(id_utilisateur, "✅ Profil enregistré.")
        if bloc == "objectif":
            return _creer_objectif(id_utilisateur, qui, reponses)
    except Exception as erreur:  # noqa: BLE001 - le refus est montré, la question reposée
        return _refus(id_utilisateur, bloc, reponses, erreur)
    return ecran(id_utilisateur)


def _limitations_finies(id_utilisateur: int, reponses: dict) -> Ecran:
    for c in ("lim_question", "lim_zone", "lim_cote", "lim_texte", "lim_autre"):
        reponses.pop(c, None)
    reponses["_limitations_faites"] = True
    _garder(id_utilisateur, "limitations", reponses)
    return ecran(id_utilisateur)


def lire_duree(texte: str) -> float | None:
    """« 50 », « 50 min », « 1h45 », « 1:45:00 », « 52:30 » : des minutes."""
    import re
    t = texte.lower().replace(" ", "").replace("minutes", "").replace("min", "")
    if m := re.fullmatch(r"(\d{1,2})h(\d{1,2})?", t):
        return int(m[1]) * 60 + int(m[2] or 0)
    if m := re.fullmatch(r"(\d{1,2}):(\d{2}):(\d{2})", t):
        return int(m[1]) * 60 + int(m[2]) + int(m[3]) / 60
    if m := re.fullmatch(r"(\d{1,3}):(\d{2})", t):
        return int(m[1]) + int(m[2]) / 60
    if m := re.fullmatch(r"\d{1,3}", t):
        return int(m[0])
    return None


def duree_en_clair(minutes: float) -> str:
    total = round(minutes * 60)
    heures, reste = divmod(total, 3600)
    mins, secs = divmod(reste, 60)
    if heures:
        return f"{heures}h{mins:02d}"
    return f"{mins} min" + (f" {secs:02d}" if secs else "")


def _creer_objectif(id_utilisateur: int, qui: Appelant, reponses: dict) -> Ecran:
    genre = reponses.get("objectif")
    if genre == "course":
        if "course_date" not in reponses:
            return ecran(id_utilisateur)
        distance = int(reponses["course_distance"])
        temps = reponses.get("course_temps")
        vise = temps not in (None, "-")
        nouveau = routes.NouvelObjectif(
            type="course", distance_m=distance,
            echeance=date.fromisoformat(reponses["course_date"]),
            cible_valeur=round(float(temps), 2) if vise else None,
            cible_unite="min" if vise else None,
            libelle=f"{distance / 1000:g} km" + (f" en {duree_en_clair(float(temps))}"
                                                  if vise else ", la finir"),
            principal=True)
    else:
        libelles = {"force": "Prendre de la force", "physique": "Prendre du muscle",
                    "endurance": "Endurance et santé"}
        nouveau = routes.NouvelObjectif(type="pilier", pilier=genre,
                                        libelle=libelles[genre], principal=True)
    rendu = routes.creer_objectif(qui, nouveau)
    # L'avis du coach arrive par son propre message (la notification) : il
    # n'est pas recopié ici, sinon il s'affiche deux fois.
    suite = " L'avis du coach arrive juste après." if rendu.get("coach") else ""
    return ecran(id_utilisateur, "✅ Objectif enregistré : " + h(nouveau.libelle) + "."
                 + suite)


def _refus(id_utilisateur: int, bloc: str | None, reponses: dict, erreur: Exception) -> Ecran:
    """Un refus de la base ou de la validation : le motif, et le bloc repris là
    où il bloque."""
    from api.coach.telegram import message_d_erreur
    motif = message_d_erreur(erreur)
    if bloc == "profil":
        # Le plus souvent la date (moins de 18 ans, PRO-7) ou la taille.
        for cle in ("naissance", "taille"):
            reponses.pop(cle, None)
    elif bloc == "limitations":
        for cle in ("lim_texte",):
            reponses.pop(cle, None)
    elif bloc == "objectif":
        for cle in ("objectif", "course_distance", "course_temps", "course_date"):
            reponses.pop(cle, None)
    elif bloc == "lieux":
        for d in DISCIPLINES:
            reponses.pop(f"lieux_{d}", None)
    _garder(id_utilisateur, "", reponses)
    return ecran(id_utilisateur, "❌ " + h(motif))
