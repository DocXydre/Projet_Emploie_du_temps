"""Ce que le coach sait de l'utilisateur à chaque appel   (COA-3, LIE-3, OBJ-12)

Le profil, l'état du dépistage, les limitations avec leur fiche, les lieux de
chaque discipline, les objectifs, la feuille de route, la trame du plan, le
rôle de chaque semaine, la pause, le carnet. Tout le reste se lit par un outil.

COA-15 : rien de ce qui est ici ne concerne l'autre personne, et aucune clé ni
aucun jeton n'y figure.
"""

from api.base import lister, un_seul
from api.coach.clair import aujourd_hui, clair, jour_en_clair, lundi_de, maintenant, sans_vides


def profil(id_utilisateur: int) -> dict | None:
    return un_seul(
        """SELECT p.date_naissance,
                  EXTRACT(YEAR FROM age(p.date_naissance))::INTEGER AS age,
                  p.sexe, p.taille_cm, p.niveau_musculation, p.niveau_course,
                  p.moment_prefere, p.jours_sans_sport, p.accord_complements,
                  p.regime, p.date_maj
             FROM profil p WHERE p.id_utilisateur = %(u)s""", {"u": id_utilisateur})


def depistage(id_utilisateur: int) -> dict | None:
    """Le dernier dépistage, et s'il bloque le plan (PRO-4 à PRO-6)."""
    ligne = un_seul(
        """SELECT d.id_depistage, d.date_reponse, d.positif, d.avis_medical_le,
                  d.coeur, d.vertiges, d.maladie_chronique, d.traitement,
                  d.os_articulations, d.grossesse, d.sedentaire_age,
                  d.date_reponse < jour_de(now()) - INTERVAL '12 months' AS perime
             FROM depistage d WHERE d.id_utilisateur = %(u)s
            ORDER BY d.date_reponse DESC, d.id_depistage DESC LIMIT 1""",
        {"u": id_utilisateur})
    if ligne is None:
        return None
    if ligne["perime"]:
        ligne["bloque"] = "Le dépistage a plus de douze mois : il est à refaire."
    elif ligne["positif"] and ligne["avis_medical_le"] is None:
        ligne["bloque"] = "Une réponse positive : avis médical requis avant de commencer."
    else:
        ligne["bloque"] = None
    return ligne


def limitations(id_utilisateur: int, actives: bool = True) -> list[dict]:
    lignes = lister(
        """SELECT l.id_limitation, l.libelle, l.zone, l.cote, l.description, l.active,
                  COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                       'code', e.code, 'libelle', e.libelle,
                                       'motif', ei.motif) ORDER BY e.libelle)
                              FROM exercice_interdit ei
                              JOIN exercice e ON e.id_exercice = ei.id_exercice
                             WHERE ei.id_limitation = l.id_limitation), '[]') AS interdits
             FROM limitation l
            WHERE l.id_utilisateur = %(u)s AND (l.active OR NOT %(actives)s)
            ORDER BY l.id_limitation""", {"u": id_utilisateur, "actives": actives})
    return lignes


def lieux(id_utilisateur: int) -> list[dict]:
    return lister(
        """SELECT dl.discipline, dl.rang, l.id_lieu, l.libelle,
                  l.minutes_domicile, l.minutes_fac,
                  to_char(l.heure_min, 'HH24:MI') AS ouvre,
                  to_char(l.heure_max, 'HH24:MI') AS ferme
             FROM discipline_lieu dl JOIN lieu_sport l ON l.id_lieu = dl.id_lieu
            WHERE dl.id_utilisateur = %(u)s
            ORDER BY dl.discipline, dl.rang""", {"u": id_utilisateur})


def objectifs(id_utilisateur: int, statut: str | None = None) -> list[dict]:
    return lister(
        """SELECT o.id_objectif, o.type, o.libelle, o.pilier, o.distance_m,
                  o.cible_valeur, o.cible_unite, e.code AS exercice, o.type_mesure,
                  o.echeance, o.principal, o.rang, o.statut, o.avis, o.avis_detail,
                  o.feuille_de_route, o.date_creation, o.date_cloture,
                  (o.echeance < jour_de(now()) AND o.statut = 'actif') AS echu
             FROM objectif o LEFT JOIN exercice e ON e.id_exercice = o.id_exercice
            WHERE o.id_utilisateur = %(u)s
              AND (%(s)s::TEXT IS NULL OR o.statut = %(s)s::TEXT)
            ORDER BY o.principal DESC, o.rang, o.id_objectif""",
        {"u": id_utilisateur, "s": statut})


def plan(id_utilisateur: int) -> dict | None:
    ligne = un_seul(
        """SELECT p.id_plan, p.id_objectif, lower(p.periode) AS du,
                  upper(p.periode) - 1 AS au, p.trame,
                  upper(p.periode) <= jour_de(now()) AS termine
             FROM plan p
            WHERE p.id_utilisateur = %(u)s AND p.statut = 'en_cours'""",
        {"u": id_utilisateur})
    if ligne is None:
        return None
    ligne["semaines"] = lister(
        """SELECT ps.lundi, ps.role, ps.intention, ps.validee_le
             FROM plan_semaine ps WHERE ps.id_plan = %(p)s ORDER BY ps.lundi""",
        {"p": ligne["id_plan"]})
    return ligne


def pause(id_utilisateur: int) -> dict | None:
    return un_seul(
        """SELECT pa.id_pause, lower(pa.periode) AS depuis, upper(pa.periode) - 1 AS jusqu_au,
                  pa.motif, jour_de(now()) - lower(pa.periode) AS jours
             FROM pause pa
            WHERE pa.id_utilisateur = %(u)s AND pa.periode @> jour_de(now())""",
        {"u": id_utilisateur})


def carnet(id_utilisateur: int) -> list[dict]:
    return lister(
        """SELECT n.id_note, n.categorie, n.texte, n.source, n.confirmee, n.date_creation
             FROM note_coach n WHERE n.id_utilisateur = %(u)s
            ORDER BY n.categorie, n.id_note""", {"u": id_utilisateur})


def reglages(id_utilisateur: int) -> dict:
    return un_seul(
        """SELECT u.nom, u.coach_actif, u.repos_dur_heures, u.seances_max_semaine,
                  u.besoin_sommeil_minutes
             FROM utilisateur u WHERE u.id_utilisateur = %(u)s""",
        {"u": id_utilisateur}) or {}


def ce_qui_manque(id_utilisateur: int) -> list[str]:
    """PRO-4, OBJ-8, LIE-6 : ce qui empêche encore de construire un plan."""
    manques = []
    if profil(id_utilisateur) is None:
        manques.append("le profil n'est pas rempli")
    etat = depistage(id_utilisateur)
    if etat is None:
        manques.append("le questionnaire de dépistage n'a pas été rempli")
    elif etat["bloque"]:
        manques.append(etat["bloque"])
    if not any(o["principal"] and o["statut"] == "actif" for o in objectifs(id_utilisateur)):
        manques.append("aucun objectif principal actif")
    if not lieux(id_utilisateur):
        manques.append("aucun lieu n'est choisi pour aucune discipline")
    return manques


def _ligne(titre: str, valeur) -> str:
    return f"- {titre} : {valeur}"


def texte(id_utilisateur: int) -> str:
    """Le contexte, tel qu'il entre dans la consigne."""
    jour = aujourd_hui()
    r = reglages(id_utilisateur)
    morceaux = [
        "# Contexte de l'utilisateur",
        f"Nous sommes le {jour_en_clair(jour)} {jour.year}, il est "
        f"{maintenant():%H:%M} à Paris. Le lundi de cette semaine est le "
        f"{lundi_de(jour).isoformat()}. L'utilisateur s'appelle {r.get('nom', '?')}.",
    ]

    p = profil(id_utilisateur)
    morceaux.append("## Profil")
    if p is None:
        morceaux.append("Le profil n'est pas rempli (PRO-4 : aucun plan tant qu'il manque).")
    else:
        jours = ", ".join(str(j) for j in p["jours_sans_sport"]) or "aucun"
        morceaux += [
            _ligne("Âge", f"{p['age']} ans"), _ligne("Sexe", p["sexe"]),
            _ligne("Taille", f"{p['taille_cm']} cm"),
            _ligne("Niveau en musculation", p["niveau_musculation"]),
            _ligne("Niveau en course", p["niveau_course"]),
            _ligne("Moment préféré", p["moment_prefere"]),
            _ligne("Jours sans sport souhaités (1 = lundi)", jours),
            _ligne("Accord pour parler de compléments alimentaires",
                   "oui" if p["accord_complements"] else "non : ne pas en parler"),
            _ligne("Régime alimentaire", p["regime"] or "non précisé"),
            _ligne("Profil mis à jour le", clair(p["date_maj"])),
        ]

    d = depistage(id_utilisateur)
    morceaux.append("## Dépistage")
    if d is None:
        morceaux.append("Pas encore rempli (PRO-4 : aucun plan tant qu'il manque).")
    else:
        etat = d["bloque"] or "valide, il ne bloque rien"
        morceaux.append(f"Rempli le {clair(d['date_reponse'])} : {etat}")
        if d["avis_medical_le"]:
            morceaux.append(f"Avis médical déclaré le {clair(d['avis_medical_le'])}.")

    morceaux.append("## Limitations permanentes")
    lims = limitations(id_utilisateur)
    if not lims:
        morceaux.append("Aucune limitation déclarée.")
    for lim in lims:
        morceaux.append(f"### {lim['libelle']} ({lim['zone']}, côté {lim['cote']})")
        morceaux.append(lim["description"])
        if lim["interdits"]:
            morceaux.append("Exercices interdits par cette limitation, refusés par la base :")
            morceaux += [f"- {i['libelle']} (`{i['code']}`) : {i['motif']}"
                         for i in lim["interdits"]]

    morceaux.append("## Lieux par discipline")
    ls = lieux(id_utilisateur)
    if not ls:
        morceaux.append("Aucun lieu choisi (LIE-6 : aucun plan pour une discipline sans lieu).")
    for lieu in ls:
        morceaux.append(
            f"- {lieu['discipline']}, rang {lieu['rang']} : {lieu['libelle']} "
            f"(id_lieu {lieu['id_lieu']}, {lieu['minutes_domicile']} min du domicile, "
            f"{lieu['minutes_fac']} min de la fac, ouvert de {lieu['ouvre']} à {lieu['ferme']})")
    sans = sorted({"musculation", "course", "cardio"} - {lieu["discipline"] for lieu in ls})
    if ls and sans:
        morceaux.append(f"Disciplines sans lieu : {', '.join(sans)}.")

    morceaux.append("## Objectifs")
    objs = [o for o in objectifs(id_utilisateur) if o["statut"] in ("actif", "en_pause")]
    if not objs:
        morceaux.append("Aucun objectif (OBJ-8 : aucun plan sans objectif principal actif).")
    feuille = None
    for o in objs:
        details = sans_vides(clair({
            "type": o["type"], "pilier": o["pilier"], "distance_m": o["distance_m"],
            "cible": o["cible_valeur"], "unite": o["cible_unite"],
            "exercice": o["exercice"], "mesure": o["type_mesure"],
            "echeance": o["echeance"], "statut": o["statut"], "avis": o["avis"]}))
        role = "PRINCIPAL" if o["principal"] else f"secondaire, rang {o['rang']}"
        echu = " (ÉCHÉANCE PASSÉE)" if o["echu"] else ""
        morceaux.append(f"- [{o['id_objectif']}] {o['libelle']} ({role}){echu} : {details}")
        if o["principal"] and o["statut"] == "actif":
            feuille = o["feuille_de_route"]
    morceaux.append("## Feuille de route de l'objectif principal")
    morceaux.append(feuille or "Pas encore écrite.")

    pl = plan(id_utilisateur)
    morceaux.append("## Plan en cours")
    if pl is None:
        morceaux.append("Aucun plan en cours.")
    else:
        fini = " Il est arrivé à son terme : il faut en construire un autre." \
            if pl["termine"] else ""
        morceaux.append(f"Du {clair(pl['du'])} au {clair(pl['au'])}.{fini}")
        morceaux.append(f"Trame : {pl['trame']}")
        for s in pl["semaines"]:
            ici = " <- semaine en cours" if s["lundi"] == lundi_de(jour) else ""
            etat = "validée" if s["validee_le"] else "pas encore validée"
            morceaux.append(f"- Semaine du {clair(s['lundi'])} : {s['role']}, {etat}"
                            f"{' : ' + s['intention'] if s['intention'] else ''}{ici}")

    pa = pause(id_utilisateur)
    if pa is not None:
        fin = f"jusqu'au {clair(pa['jusqu_au'])}" if pa["jusqu_au"] else "sans date de fin"
        morceaux.append("## Pause en cours")
        morceaux.append(
            f"Le coach est en pause depuis le {clair(pa['depuis'])}, {fin}. Motif : "
            f"{pa['motif'] or 'non précisé'}. Tu ne proposes aucune séance et tu ne déposes "
            "aucun ajustement : la base le refuse (PAU-2).")

    morceaux.append("## Réglages du compte")
    morceaux.append(_ligne("Repos entre deux séances dures d'un même groupe",
                           f"{r.get('repos_dur_heures', 48)} h (SEC-3, tenu par la base)"))
    maximum = r.get("seances_max_semaine")
    morceaux.append(_ligne("Maximum de séances par semaine",
                           maximum if maximum else "non fixé, tu décides"))
    morceaux.append(_ligne("Besoin de sommeil",
                           f"{r.get('besoin_sommeil_minutes', 480) // 60} h"))

    morceaux.append("## Carnet")
    notes = carnet(id_utilisateur)
    if not notes:
        morceaux.append("Le carnet est vide.")
    for n in notes:
        origine = "dit par l'utilisateur" if n["source"] == "utilisateur" else (
            "déduction confirmée" if n["confirmee"] else "déduction NON confirmée")
        morceaux.append(f"- [{n['id_note']}] ({n['categorie']}, {origine}, "
                        f"{clair(n['date_creation'])}) {n['texte']}")

    return "\n".join(morceaux)
