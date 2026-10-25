"""Les lieux connus : adresses, mémoire, trajets              (ADR, opération H1)

Un lieu se donne par son adresse, dite à HAL ou corrigée dans Réglages. Ce
module la cherche à la Géoplateforme de l'IGN, garde le lieu, puis calcule les
trajets dont le placement et HAL ont besoin, avec OSRM sur les cartes
OpenStreetMap (ADR-8).

    1. chercher une adresse, ou celle d'une position              (ADR-4)
    2. créer ou mettre à jour un lieu, son mode, sa description
                                                    (ADR-1 à ADR-7, ADR-11, ADR-15)
    3. compléter les trajets qui manquent                         (ADR-8)
    4. ce que HAL lit des lieux                          (ADR-10, ADR-12)

Les deux services sont gratuits et sans clé. Un service muet ne bloque rien :
un trajet se rabat sur une estimation à vol d'oiseau, marquée comme telle.
"""

import logging
import math

import httpx

from api.base import connexion, executer, lister, un_seul

LOG = logging.getLogger(__name__)

GEOCODAGE = "https://data.geopf.fr/geocodage"
OSRM = "https://routing.openstreetmap.de/routed-{profil}/route/v1/driving/{depart};{arrivee}"
PROFILS = {"pied": "foot", "velo": "bike", "voiture": "car"}
DELAI_SECONDES = 6.0

NATURES = ("foyer", "sport", "etudes", "travail", "sejour", "autre")
MODES = ("pied", "velo", "voiture")
# Les lieux d'où l'on part pour aller faire du sport (ADR-9, ADR-10).
DEPARTS = ("foyer", "etudes", "travail", "sejour")

# ADR-7 : au-delà, on prend la voiture (comme `mode_du_trajet`).
LOIN_A_PIED = 5000
LOIN_A_VELO = 20000

# ADR-8, annexe 3 : l'estimation à vol d'oiseau, faute de calcul.
DETOUR = 1.3
VITESSES_KMH = {"pied": 5.0, "velo": 15.0, "voiture": 50.0}

# ADR-4 : une commune entière n'est pas une adresse de salle. Elle passe pour un
# lieu de séjour ou un autre, avec un cercle plus large.
RAYON_D_UNE_COMMUNE = 500

# ADR-15 : le battement d'un lieu de sport donné par adresse.
BATTEMENT_MINUTES = 15


class AdresseIntrouvable(Exception):
    """ADR-4 : rien trouvé, ou trop vague pour ce lieu. Le motif se lit tel quel."""


# ---------------------------------------------------------------------------
# 1. Les adresses                                                     (ADR-4)
# ---------------------------------------------------------------------------

def _premier(reponse: httpx.Response) -> dict | None:
    reponse.raise_for_status()
    elements = reponse.json().get("features") or []
    if not elements:
        return None
    x = elements[0]
    lon, lat = x["geometry"]["coordinates"]
    p = x.get("properties") or {}
    return {"adresse": (p.get("label") or "")[:200], "latitude": round(lat, 6),
            "longitude": round(lon, 6), "type": p.get("type"), "score": p.get("score")}


def chercher_adresse(texte: str) -> dict:
    """La meilleure adresse pour ce texte. Lève AdresseIntrouvable."""
    texte = (texte or "").strip()
    if len(texte) < 3:
        raise AdresseIntrouvable("L'adresse est vide ou trop courte")
    try:
        trouve = _premier(httpx.get(f"{GEOCODAGE}/search", params={"q": texte, "limit": 1},
                                    timeout=DELAI_SECONDES))
    except httpx.HTTPError as erreur:
        raise AdresseIntrouvable(
            f"Le service des adresses ne répond pas ({type(erreur).__name__}). "
            "Réessaie dans un moment") from erreur
    if trouve is None or (trouve["score"] or 0) < 0.4:
        raise AdresseIntrouvable(f"Aucune adresse trouvée pour « {texte} »")
    return trouve


def adresse_proche(latitude: float, longitude: float) -> str:
    """L'adresse la plus proche d'une position, ou ses coordonnées si rien ne répond."""
    try:
        trouve = _premier(httpx.get(f"{GEOCODAGE}/reverse",
                                    params={"lat": latitude, "lon": longitude, "limit": 1},
                                    timeout=DELAI_SECONDES))
    except httpx.HTTPError:
        trouve = None
    return trouve["adresse"] if trouve else f"{latitude:.5f}, {longitude:.5f}"


# ---------------------------------------------------------------------------
# 2. Les lieux                                               (ADR-1 à ADR-7)
# ---------------------------------------------------------------------------

def lieux_du_compte(id_utilisateur: int) -> list[dict]:
    """Les lieux du compte, avec ce qu'il en dit : mode, description, lieu de sport."""
    return lister(
        """SELECT l.id_lieu_connu, l.nom, l.nature, l.adresse, l.latitude, l.longitude,
                  l.rayon_m, l.id_utilisateur IS NULL AS commun,
                  mode_trajet_de(%(u)s, l.id_lieu_connu) AS mode_trajet,
                  m.texte AS description, m.quand AS description_le,
                  (SELECT array_agg(ls.libelle ORDER BY ls.id_lieu) FROM lieu_sport ls
                    WHERE ls.id_lieu_connu = l.id_lieu_connu) AS lieux_de_sport
             FROM lieux_du_compte(%(u)s) l
             LEFT JOIN LATERAL (
                  SELECT texte, quand FROM description_lieu dl
                   WHERE dl.id_utilisateur = %(u)s AND dl.id_lieu_connu = l.id_lieu_connu
                   ORDER BY id_description_lieu DESC LIMIT 1) m ON TRUE
            ORDER BY CASE l.nature WHEN 'foyer' THEN 0 ELSE 1 END, l.nom""",
        {"u": id_utilisateur})


def _trouver(id_utilisateur: int, nom: str | None, id_lieu_sport: int | None,
             id_lieu_connu: int | None) -> dict | None:
    if id_lieu_connu is not None:
        return un_seul("SELECT * FROM lieux_du_compte(%(u)s) WHERE id_lieu_connu = %(l)s",
                       {"u": id_utilisateur, "l": id_lieu_connu})
    if id_lieu_sport is not None:
        ligne = un_seul(
            """SELECT l.* FROM lieu_sport s JOIN lieux_du_compte(%(u)s) l
                   ON l.id_lieu_connu = s.id_lieu_connu WHERE s.id_lieu = %(s)s""",
            {"u": id_utilisateur, "s": id_lieu_sport})
        if ligne:
            return ligne
    if nom:
        return un_seul("SELECT * FROM lieux_du_compte(%(u)s) WHERE lower(nom) = lower(%(n)s)",
                       {"u": id_utilisateur, "n": nom.strip()})
    return None


def noter_lieu(id_utilisateur: int, *, nom: str | None = None, adresse: str | None = None,
               ici: bool = False, nature: str | None = None, rayon_m: int | None = None,
               mode_trajet: str | None = None, id_lieu_sport: int | None = None,
               id_lieu_connu: int | None = None, description: str | None = None,
               auteur: str = "utilisateur") -> dict:
    """Crée ou met à jour un lieu connu (opération H1). Rend le lieu, et ce qui a changé.

    Le lieu du foyer va au foyer du compte ; le reste lui est personnel, les
    lieux de sport compris (ADR-1, ADR-2). Lève AdresseIntrouvable ou
    ValueError, avec un motif à lire tel quel.
    """
    if nature is not None and nature not in NATURES:
        raise ValueError(f"« nature » vaut {', '.join(NATURES)}")
    if mode_trajet is not None and mode_trajet not in MODES:
        raise ValueError(f"« mode_trajet » vaut {', '.join(MODES)}")
    if id_lieu_sport is not None and un_seul(
            "SELECT 1 AS ok FROM lieu_sport WHERE id_lieu = %(s)s", {"s": id_lieu_sport}) is None:
        raise ValueError(f"Aucun lieu de sport n° {id_lieu_sport}")
    existant = _trouver(id_utilisateur, nom, id_lieu_sport, id_lieu_connu)
    if existant is None and id_lieu_connu is not None:
        raise ValueError("Ce lieu n'est pas un de tes lieux connus")

    trouve = None
    if ici:
        pos = un_seul("SELECT latitude, longitude FROM position_actuelle "
                      "WHERE id_utilisateur = %(u)s AND latitude IS NOT NULL",
                      {"u": id_utilisateur})
        if pos is None:
            raise AdresseIntrouvable("Je ne connais pas encore ta position : le suivi de la "
                                     "position n'a rien envoyé")
        lat, lon = float(pos["latitude"]), float(pos["longitude"])
        trouve = {"adresse": adresse_proche(lat, lon)[:200], "latitude": lat,
                  "longitude": lon, "type": "position"}
    elif adresse:
        trouve = chercher_adresse(adresse)

    if existant is None:
        if trouve is None:
            raise ValueError("Un nouveau lieu a besoin d'une adresse, ou d'« ici »")
        if not (nom or "").strip():
            if id_lieu_sport is None:
                raise ValueError("Un nouveau lieu a besoin d'un nom")
            nom = un_seul("SELECT libelle FROM lieu_sport WHERE id_lieu = %(s)s",
                          {"s": id_lieu_sport})["libelle"]
        nature = nature or ("sport" if id_lieu_sport is not None else "autre")

    nature_finale = nature or existant["nature"]
    if trouve and trouve.get("type") == "municipality" and nature_finale not in ("sejour", "autre"):
        raise AdresseIntrouvable(
            f"« {trouve['adresse']} » est une commune entière : il faut le numéro et la rue, "
            "ou poser le lieu « ici » quand tu y es")
    if trouve and trouve.get("type") == "municipality" and rayon_m is None:
        rayon_m = RAYON_D_UNE_COMMUNE

    foyer = un_seul("SELECT id_foyer FROM utilisateur WHERE id_utilisateur = %(u)s",
                    {"u": id_utilisateur})["id_foyer"]
    # ADR-1 : seul le foyer est commun. Une salle est à celui qui la donne : sa
    # description dit ce qu'elle est pour lui (ADR-11).
    commun = nature_finale == "foyer" and foyer is not None
    if nature_finale == "foyer" and foyer is None:
        raise ValueError("Le foyer n'existe pas encore : son adresse attend qu'il soit ouvert")

    with connexion() as conn, conn.cursor() as cur:
        if existant is None:
            cur.execute(
                """INSERT INTO lieu_connu (id_foyer, id_utilisateur, nom, nature, adresse,
                                           latitude, longitude, rayon_m)
                   VALUES (%(f)s, %(u)s, %(n)s, %(na)s, %(a)s, %(la)s, %(lo)s,
                           COALESCE(%(r)s, 50))
                   RETURNING id_lieu_connu""",
                {"f": foyer if commun else None, "u": None if commun else id_utilisateur,
                 "n": nom.strip()[:60], "na": nature_finale, "a": trouve["adresse"],
                 "la": trouve["latitude"], "lo": trouve["longitude"], "r": rayon_m})
            id_lieu = cur.fetchone()["id_lieu_connu"]
        else:
            id_lieu = existant["id_lieu_connu"]
            cur.execute(
                """UPDATE lieu_connu
                      SET nom = COALESCE(%(n)s, nom), nature = %(na)s,
                          adresse = COALESCE(%(a)s, adresse),
                          latitude = COALESCE(%(la)s, latitude),
                          longitude = COALESCE(%(lo)s, longitude),
                          rayon_m = COALESCE(%(r)s, rayon_m), modifie_le = now()
                    WHERE id_lieu_connu = %(l)s""",
                {"n": (nom or "").strip()[:60] or None, "na": nature_finale,
                 "a": trouve and trouve["adresse"], "la": trouve and trouve["latitude"],
                 "lo": trouve and trouve["longitude"], "r": rayon_m, "l": id_lieu})
            if trouve:
                # ADR-8 : une adresse qui change refait ses trajets.
                cur.execute("DELETE FROM trajet_calcule WHERE %(l)s IN (id_depart, id_arrivee)",
                            {"l": id_lieu})
        if id_lieu_sport is not None:
            cur.execute("UPDATE lieu_sport SET id_lieu_connu = %(l)s WHERE id_lieu = %(s)s",
                        {"l": id_lieu, "s": id_lieu_sport})
        elif nature_finale == "sport":
            # ADR-15 : un lieu de sport a son lieu de placement, ouvert jour et nuit
            # pour la base ; ses vraies heures sont dans sa description (ADR-16).
            cur.execute(
                """INSERT INTO lieu_sport (code, libelle, minutes_domicile, minutes_fac,
                                           heure_min, heure_max, preference, marge_minutes,
                                           id_lieu_connu)
                   SELECT 'LIEU_' || l.id_lieu_connu, l.nom, 0, 0, '00:00', '23:59', 'tot',
                          %(m)s, l.id_lieu_connu
                     FROM lieu_connu l
                    WHERE l.id_lieu_connu = %(l)s
                      AND NOT EXISTS (SELECT 1 FROM lieu_sport s
                                       WHERE s.id_lieu_connu = l.id_lieu_connu)""",
                {"l": id_lieu, "m": BATTEMENT_MINUTES})
            cur.execute("""UPDATE lieu_sport s SET libelle = l.nom FROM lieu_connu l
                            WHERE s.id_lieu_connu = l.id_lieu_connu AND l.id_lieu_connu = %(l)s
                              AND s.code = 'LIEU_' || l.id_lieu_connu""", {"l": id_lieu})
        if mode_trajet is not None:
            cur.execute(
                """INSERT INTO lieu_de_chacun (id_utilisateur, id_lieu_connu, mode_trajet)
                   VALUES (%(u)s, %(l)s, %(m)s)
                   ON CONFLICT (id_utilisateur, id_lieu_connu)
                   DO UPDATE SET mode_trajet = EXCLUDED.mode_trajet""",
                {"u": id_utilisateur, "l": id_lieu, "m": mode_trajet})

    if description is not None:
        ecrire_description(id_utilisateur, id_lieu, description, auteur)
    completer_trajets(id_utilisateur)
    lieu = next(x for x in lieux_du_compte(id_utilisateur) if x["id_lieu_connu"] == id_lieu)
    lieu["trajets_depuis"] = trajets_vers(id_utilisateur, id_lieu)
    lieu["cree"] = existant is None
    return lieu


def ecrire_description(id_utilisateur: int, id_lieu_connu: int, texte: str,
                       auteur: str) -> int | None:
    """ADR-11 : une version de plus de la description d'un lieu, pour ce compte."""
    ligne = executer("SELECT ecrire_description_lieu(%(u)s, %(l)s, %(t)s, %(a)s) AS id",
                     {"u": id_utilisateur, "l": id_lieu_connu, "t": texte, "a": auteur})
    return (ligne or {}).get("id")


# ---------------------------------------------------------------------------
# 3. Les trajets                                                      (ADR-8)
# ---------------------------------------------------------------------------

def estimation(lat1, lon1, lat2, lon2, mode: str) -> tuple[int, int]:
    """À vol d'oiseau, avec un détour de 30 %. Rend (minutes, mètres)."""
    p1, p2 = math.radians(float(lat1)), math.radians(float(lat2))
    dp, dl = p2 - p1, math.radians(float(lon2) - float(lon1))
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    metres = 2 * 6371000 * math.asin(math.sqrt(a)) * DETOUR
    minutes = metres / 1000 / VITESSES_KMH[mode] * 60
    return max(1, round(minutes)), round(metres)


def calculer(lat1, lon1, lat2, lon2, mode: str) -> tuple[int, int, bool]:
    """Le trajet par OSRM : (minutes, mètres, estimé). Un échec rend l'estimation."""
    url = OSRM.format(profil=PROFILS[mode], depart=f"{float(lon1)},{float(lat1)}",
                      arrivee=f"{float(lon2)},{float(lat2)}")
    try:
        reponse = httpx.get(url, params={"overview": "false"}, timeout=DELAI_SECONDES)
        reponse.raise_for_status()
        route = (reponse.json().get("routes") or [None])[0]
        if route:
            return max(1, round(route["duration"] / 60)), round(route["distance"]), False
    except (httpx.HTTPError, ValueError, KeyError) as erreur:
        LOG.info("Trajet OSRM impossible (%s) : %s", mode, erreur)
    minutes, metres = estimation(lat1, lon1, lat2, lon2, mode)
    return minutes, metres, True


def _manquants(id_utilisateur: int | None) -> list[dict]:
    """Les trajets dont un compte a besoin et qui ne sont pas calculés (ou seulement
    estimés) : de chacun de ses lieux de départ vers chacun des lieux de sport qui
    ont une adresse, dans son mode."""
    return lister(
        """SELECT DISTINCT d.id_lieu_connu AS depart, a.id_lieu_connu AS arrivee, x.mode,
                  d.latitude AS lat1, d.longitude AS lon1,
                  a.latitude AS lat2, a.longitude AS lon2
             FROM utilisateur u
             CROSS JOIN LATERAL lieux_du_compte(u.id_utilisateur) d
             CROSS JOIN LATERAL lieux_du_compte(u.id_utilisateur) a
             CROSS JOIN LATERAL (SELECT mode_du_trajet(u.id_utilisateur, d.id_lieu_connu,
                                                       a.id_lieu_connu) AS mode) x
            WHERE u.actif AND (%(u)s::INTEGER IS NULL OR u.id_utilisateur = %(u)s)
              AND d.nature = ANY(%(departs)s) AND d.id_lieu_connu <> a.id_lieu_connu
              AND (a.nature = 'sport' OR EXISTS (SELECT 1 FROM lieu_sport s
                                                  WHERE s.id_lieu_connu = a.id_lieu_connu))
              AND NOT EXISTS (SELECT 1 FROM trajet_calcule t
                               WHERE t.id_depart = d.id_lieu_connu
                                 AND t.id_arrivee = a.id_lieu_connu
                                 AND t.mode = x.mode
                                 AND (NOT t.estime OR t.calcule_le > now() - INTERVAL '1 day'))""",
        {"u": id_utilisateur, "departs": list(DEPARTS)})


def completer_trajets(id_utilisateur: int | None = None) -> int:
    """ADR-8 : calcule ce qui manque. Une estimation se recalcule le lendemain."""
    faits = 0
    for t in _manquants(id_utilisateur):
        minutes, metres, estime = calculer(t["lat1"], t["lon1"], t["lat2"], t["lon2"], t["mode"])
        executer(
            """INSERT INTO trajet_calcule (id_depart, id_arrivee, mode, minutes, metres, estime)
               VALUES (%(d)s, %(a)s, %(m)s, %(mi)s, %(me)s, %(e)s)
               ON CONFLICT (id_depart, id_arrivee, mode) DO UPDATE
                  SET minutes = EXCLUDED.minutes, metres = EXCLUDED.metres,
                      estime = EXCLUDED.estime, calcule_le = now()""",
            {"d": t["depart"], "a": t["arrivee"], "m": t["mode"], "mi": minutes,
             "me": metres, "e": estime})
        faits += 1
    return faits


def trajets_vers(id_utilisateur: int, id_lieu_connu: int) -> list[dict]:
    """Les trajets calculés vers un lieu, depuis chaque lieu de départ du compte."""
    return lister(
        """SELECT d.nom AS depuis, d.nature, t.minutes, t.metres, t.mode, t.estime
             FROM trajet_calcule t
             JOIN lieux_du_compte(%(u)s) d ON d.id_lieu_connu = t.id_depart
            WHERE t.id_arrivee = %(l)s AND t.mode = mode_du_trajet(%(u)s, t.id_depart, %(l)s)
            ORDER BY CASE d.nature WHEN 'foyer' THEN 0 WHEN 'etudes' THEN 1 ELSE 2 END,
                     d.nom""",
        {"u": id_utilisateur, "l": id_lieu_connu})


# ---------------------------------------------------------------------------
# 4. Ce que HAL lit                                          (ADR-10, ADR-12)
# ---------------------------------------------------------------------------

def ou_je_suis(id_utilisateur: int) -> dict:
    """La présence en cours, si la position est sue (POS-6)."""
    ligne = un_seul(
        """SELECT position_sue(%(u)s) AS sue, pr.id_presence, lower(pr.periode) AS depuis,
                  l.id_lieu_connu, l.nom, l.nature, p.latitude, p.longitude, p.releve_le,
                  p.autorisation, p.precise, p.ecrit_le
             FROM utilisateur u
             LEFT JOIN position_actuelle p ON p.id_utilisateur = u.id_utilisateur
             LEFT JOIN presence pr ON pr.id_utilisateur = u.id_utilisateur
                                  AND upper_inf(pr.periode)
             LEFT JOIN lieu_connu l ON l.id_lieu_connu = pr.id_lieu_connu
            WHERE u.id_utilisateur = %(u)s""", {"u": id_utilisateur})
    return ligne or {"sue": False}


def _depuis_ici(id_utilisateur: int, ici: dict, lieu: dict) -> int | None:
    """Le trajet depuis là où l'on est : le trajet calculé si l'on est dans un lieu
    connu, sinon une estimation à vol d'oiseau (pas d'appel à OSRM à chaque appel
    de HAL)."""
    if not ici.get("sue") or ici.get("latitude") is None:
        return None
    if ici.get("id_lieu_connu") == lieu["id_lieu_connu"]:
        return 0
    if ici.get("id_lieu_connu"):
        ligne = un_seul(
            """SELECT minutes FROM trajet_calcule WHERE id_depart = %(d)s AND id_arrivee = %(a)s
                  AND mode = mode_du_trajet(%(u)s, %(d)s, %(a)s)""",
            {"d": ici["id_lieu_connu"], "a": lieu["id_lieu_connu"], "u": id_utilisateur})
        if ligne:
            return ligne["minutes"]
    mode = lieu["mode_trajet"]
    _, metres = estimation(ici["latitude"], ici["longitude"], lieu["latitude"],
                           lieu["longitude"], mode)
    if (mode == "pied" and metres > LOIN_A_PIED * DETOUR) or \
            (mode == "velo" and metres > LOIN_A_VELO * DETOUR):
        mode = "voiture"
    return estimation(ici["latitude"], ici["longitude"], lieu["latitude"], lieu["longitude"],
                      mode)[0]


def _lieu_a_venir(id_utilisateur: int) -> dict | None:
    """ADR-12 : le lieu connu de la prochaine absence, dans les sept jours."""
    return un_seul(
        """SELECT l.id_lieu_connu, l.nom, lower(a.periode) AS debut, upper(a.periode) AS fin
             FROM absence a JOIN lieu_connu l ON l.id_lieu_connu = a.id_lieu_connu
            WHERE a.id_utilisateur = %(u)s AND upper(a.periode) > now()
              AND lower(a.periode) < now() + INTERVAL '7 days'
            ORDER BY lower(a.periode) LIMIT 1""", {"u": id_utilisateur})


def texte_pour_hal(id_utilisateur: int, hal: str = "sport") -> str:
    """Les lieux, où l'on est, et les descriptions utiles (ADR-10, ADR-12, POS-5).

    Rien que pour le compte qui parle. Le HAL du foyer n'a pas les trajets vers
    les lieux de sport : il ne place pas les séances.
    """
    from api.coach.clair import clair
    lieux = lieux_du_compte(id_utilisateur)
    if not lieux:
        return ("# Lieux et position\nAucun lieu n'a d'adresse. Les trajets des séances sont "
                "les minutes saisies des lieux de sport. Si l'utilisateur te donne une adresse "
                "(son foyer, sa salle, l'école, un lieu où il dort), note-la avec `noter_lieu`, "
                "et ce qu'il en dit dans sa description.")
    ici = ou_je_suis(id_utilisateur)
    lignes = ["# Lieux et position"]
    if ici.get("sue") and ici.get("id_presence"):
        ou = ici["nom"] or "ailleurs, dans aucun lieu connu"
        lignes.append(f"Maintenant : {ou}, depuis {clair(ici['depuis'])}.")
    elif ici.get("autorisation") in (None, "inconnue"):
        lignes.append("Position : le suivi n'est pas en marche (Réglages, Lieux).")
    else:
        lignes.append("Position : pas sue en ce moment (POS-6).")
    a_venir = _lieu_a_venir(id_utilisateur)
    utiles = {ici.get("id_lieu_connu"), (a_venir or {}).get("id_lieu_connu")}
    if a_venir:
        lignes.append(f"Absence prévue à {a_venir['nom']}, du {clair(a_venir['debut'])} "
                      f"au {clair(a_venir['fin'])}.")
    lignes.append("Les lieux connus (id_lieu_connu, nature, mode de trajet) :")
    for x in lieux:
        morceaux = [f"- {x['nom']} (id {x['id_lieu_connu']}, {x['nature']}, "
                    f"{x['mode_trajet']}) : {x['adresse']}"]
        if x["lieux_de_sport"]:
            morceaux.append(f"lieu de sport : {', '.join(x['lieux_de_sport'])}")
        if hal == "sport" and (x["nature"] == "sport" or x["lieux_de_sport"]):
            trajets = [f"{t['minutes']} min depuis {t['depuis']}"
                       + (" (estimé)" if t["estime"] else "")
                       for t in trajets_vers(id_utilisateur, x["id_lieu_connu"])]
            d = _depuis_ici(id_utilisateur, ici, x)
            if d is not None:
                trajets.append(f"{d} min depuis là où tu es")
            if trajets:
                morceaux.append("trajet " + ", ".join(trajets))
        lignes.append(" ; ".join(morceaux))
        # ADR-12 : celle d'un lieu de sport sert à choisir le lieu d'une séance.
        sport = x["nature"] == "sport" or x["lieux_de_sport"]
        if x["description"] and (x["id_lieu_connu"] in utiles or (hal == "sport" and sport)):
            lignes.append(f"  Description de {x['nom']} : {x['description']}")
        elif x["description"]:
            lignes.append("  (a une description : `lire_lieux` la rend)")
    return "\n".join(lignes)
