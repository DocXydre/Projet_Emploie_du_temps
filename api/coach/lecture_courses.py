"""Ce que HAL lit d'une course                                       (SAN-17)

La base garde chaque mesure de la montre (SAN-11) et `detail_activite()` en tire
les étapes, les kilomètres, la courbe, les zones. HAL n'a pas besoin des mesures :
il lui faut ce qui permet de régler la séance suivante. Chaque course se lit
donc en phrases courtes, étape par étape, à côté de ce qui était prévu :

- chaque étape, avec son temps, son allure, sa FC moyenne et finale, et l'écart
  au prévu quand la séance est partie sur la montre avec ses étapes (MON-1) ;
- les fractions en une ligne : les temps, combien tiennent l'objectif, la FC en
  fin de fraction, ce qu'elle redescend pendant les récupérations ;
- pour une sortie continue, la dérive cardiaque : la FC à allure égale, entre la
  première et la seconde moitié, échauffement mis à part ;
- les kilomètres, les zones, la dynamique de course, la FC de récupération.

Le tracé GPS n'est jamais envoyé : il ne dit rien de l'entraînement, et il dit
où l'utilisateur court. Il sert seulement, ici, à rapporter le vent au parcours :
la météo du départ, la part face au vent et l'allure de chaque côté (MTO-8).
"""

from datetime import date, datetime, timedelta

from api.base import lister, un_seul
from api.coach.clair import aujourd_hui, clair

# Au-delà, une dérive se lit comme un signe de fatigue ou de chaleur (chapitre 8.1).
DERIVE_NOTABLE = 5.0


def allure(secondes: int | float | None) -> str | None:
    if not secondes:
        return None
    secondes = int(round(secondes))
    return f"{secondes // 60}:{secondes % 60:02d} /km"


def chrono(secondes: int | float | None) -> str:
    secondes = int(round(secondes or 0))
    if secondes >= 3600:
        return f"{secondes // 3600} h {secondes % 3600 // 60:02d}"
    return f"{secondes // 60}:{secondes % 60:02d}"


def _km(metres) -> str:
    return f"{float(metres) / 1000:.2f} km".replace(".", ",")


def _nombre(valeur: float, decimales: int = 1) -> str:
    return f"{valeur:.{decimales}f}".replace(".", ",")


def _prevu(prevu: dict | None) -> str | None:
    if not prevu:
        return None
    morceaux = []
    if prevu.get("distance_m") and prevu.get("objectif_s"):
        morceaux.append(f"{prevu['distance_m']} m en {chrono(prevu['objectif_s'])}")
    elif prevu.get("distance_m"):
        morceaux.append(f"{prevu['distance_m']} m")
    elif prevu.get("duree_s"):
        morceaux.append(chrono(prevu["duree_s"]))
    if prevu.get("zone"):
        morceaux.append(f"en zone {prevu['zone']}")
    if prevu.get("allure"):
        morceaux.append("en trottinant" if prevu["allure"] == "trot" else prevu["allure"])
    return " ".join(morceaux) or None


def _ligne_etape(e: dict) -> str:
    morceaux = [f"{e['nom']} : {chrono(e['duree_s'])}"]
    if e.get("distance_m"):
        morceaux.append(f"{int(e['distance_m'])} m" if e["distance_m"] < 1000
                        else _km(e["distance_m"]))
    if e.get("allure_s_km"):
        morceaux.append(allure(e["allure_s_km"]))
    if e.get("fc"):
        fc = f"FC {e['fc']}"
        if e.get("fc_fin") and e["fc_fin"] != e["fc"]:
            fc += f", {e['fc_fin']} à la fin"
        morceaux.append(fc)
    ligne = ", ".join(morceaux)
    prevu = _prevu(e.get("prevu"))
    if prevu:
        ligne += f" (prévu {prevu}"
        objectif = (e.get("prevu") or {}).get("objectif_s")
        if objectif:
            ecart = e["duree_s"] - objectif
            ligne += ", tenu" if abs(ecart) <= 3 else f", {'+' if ecart > 0 else '−'}{abs(ecart)} s"
        ligne += ")"
    return ligne


def _fractions(etapes: list[dict]) -> str | None:
    fractions = [e for e in etapes if e.get("rapide")]
    if len(fractions) < 2:
        return None
    premiere, derniere = fractions[0]["rang"], fractions[-1]["rang"]
    recups = [e for e in etapes if not e.get("rapide") and premiere < e["rang"] < derniere]
    temps = ", ".join(chrono(f["duree_s"]) for f in fractions)
    phrase = f"{len(fractions)} fractions : {temps}"
    objectifs = [(f["duree_s"], (f.get("prevu") or {}).get("objectif_s")) for f in fractions]
    if all(o for _, o in objectifs):
        tenues = sum(1 for d, o in objectifs if d <= o + 3)
        phrase += f" (objectif {chrono(objectifs[0][1])}, {tenues} tenues sur {len(fractions)})"
    ecart = fractions[-1]["duree_s"] - fractions[0]["duree_s"]
    if abs(ecart) > 3:
        phrase += f". La dernière {'perd' if ecart > 0 else 'gagne'} {abs(ecart)} s sur la première"
    fins = [f["fc_fin"] for f in fractions if f.get("fc_fin")]
    if fins:
        phrase += f". FC en fin de fraction : {min(fins)} à {max(fins)}"
    if recups:
        duree = sum(r["duree_s"] for r in recups) / len(recups)
        phrase += f". Récupérations de {chrono(duree)} en moyenne"
        bas = [r["fc_fin"] for r in recups if r.get("fc_fin")]
        if bas:
            phrase += f", la FC redescend à {round(sum(bas) / len(bas))} avant la suivante"
    return phrase + "."


def _derive(detail: dict) -> str | None:
    """La FC à allure égale (FC × allure), seconde moitié contre première, sur la
    partie continue la plus longue, sans ses cinq premières minutes."""
    etapes = detail.get("etapes") or []
    if any(e.get("rapide") for e in etapes):
        continues = [e for e in etapes if not e.get("rapide") and e["duree_s"] >= 20 * 60]
        if not continues:
            return None
        e = max(continues, key=lambda x: x["duree_s"])
        debut, fin = e["debut_s"], e["debut_s"] + e["duree_s"]
    else:
        debut, fin = 0, detail.get("duree_secondes") or 0
    if fin - debut < 20 * 60:
        return None
    points = [p for p in detail.get("courbe") or []
              if debut + 300 <= p["t"] < fin and p.get("fc") and p.get("allure_s_km")]
    if len(points) < 20:
        return None
    milieu = len(points) // 2
    cout = [p["fc"] * p["allure_s_km"] for p in points]
    avant, apres = sum(cout[:milieu]) / milieu, sum(cout[milieu:]) / (len(cout) - milieu)
    derive = (apres / avant - 1) * 100
    phrase = (f"Dérive cardiaque {'+' if derive >= 0 else '−'}{_nombre(abs(derive))} % "
              "(FC à allure égale, seconde moitié contre première)")
    if derive >= DERIVE_NOTABLE:
        phrase += " : notable"
    return phrase + "."


def _zones(detail: dict) -> str | None:
    zones = detail.get("zones")
    if not zones or not sum(zones):
        return None
    texte = ", ".join(f"Z{i + 1} {round(s / 60)} min" for i, s in enumerate(zones))
    if detail.get("fc_max_connue"):
        texte += (f" (sur une FC max connue de {detail['fc_max_connue']} : Z1 sous 60 %, "
                  "Z2 60-70, Z3 70-80, Z4 80-90, Z5 au-delà)")
    return texte


def _dynamique(detail: dict) -> str | None:
    d = detail.get("dynamique") or {}
    formats = (("puissance", "puissance", lambda v: f"{round(v)} W"),
               ("cadence", "cadence", lambda v: f"{round(v)} pas/min"),
               ("foulee", "foulée", lambda v: f"{_nombre(v, 2)} m"),
               ("contact_sol", "contact au sol", lambda v: f"{round(v)} ms"),
               ("oscillation", "oscillation", lambda v: f"{_nombre(v)} cm"))
    morceaux = []
    for cle, nom, ecrire in formats:
        valeurs = d.get(cle) or {}
        if valeurs.get("moyenne") is None:
            continue
        texte = f"{nom} {ecrire(valeurs['moyenne'])}"
        if valeurs.get("fractions") is not None:
            texte += f" ({ecrire(valeurs['fractions'])} en fraction)"
        morceaux.append(texte)
    return ", ".join(morceaux) or None


def _titre(detail: dict) -> str:
    fractions = [e for e in detail.get("etapes") or [] if e.get("rapide")]
    if len(fractions) >= 2:
        distances = [f.get("distance_m") for f in fractions]
        if all(distances):
            moyenne = round(sum(distances) / len(distances) / 100) * 100
            return f"Fractionné {len(fractions)} × {moyenne} m"
        return f"Fractionné, {len(fractions)} fractions"
    return "Course continue" if detail.get("courbe") else "Course"


def _resume(detail: dict) -> str:
    debut = detail["debut"]
    # Rendu par la base en JSON, donc en UTC : à l'heure de Paris pour le modèle.
    quand = clair(datetime.fromisoformat(debut) if isinstance(debut, str) else debut)
    morceaux = [f"{_titre(detail)}, {quand}"]
    if detail.get("distance_m"):
        morceaux.append(f"{_km(detail['distance_m'])} en {chrono(detail.get('duree_secondes'))}")
    if detail.get("allure_s_km"):
        morceaux.append(allure(detail["allure_s_km"]))
    if detail.get("fc_moyenne"):
        morceaux.append(f"FC {detail['fc_moyenne']}"
                        + (f" (max {detail['fc_max']})" if detail.get("fc_max") else ""))
    if detail.get("denivele_m"):
        morceaux.append(f"D+ {detail['denivele_m']} m")
    return " · ".join(morceaux)


def en_clair(detail: dict, complet: bool = True) -> dict:
    """Une course pour HAL. `complet` ajoute chaque étape et chaque kilomètre."""
    etapes = detail.get("etapes") or []
    rendu = {"seance": _resume(detail),
             "id_occurrence": detail.get("id_occurrence"),
             "fractions": _fractions(etapes),
             "derive_cardiaque": _derive(detail)}
    if complet:
        if len(etapes) > 1:
            rendu["etapes"] = [_ligne_etape(e) for e in etapes]
        kilometres = detail.get("kilometres") or []
        if kilometres:
            rendu["kilometres"] = " | ".join(
                f"{k['rang']} : {chrono(k['duree_s'])}" + (f" FC {k['fc']}" if k.get("fc") else "")
                for k in kilometres)
        rendu["zones"] = _zones(detail)
        rendu["dynamique"] = _dynamique(detail)
        pauses = detail.get("pauses") or []
        if pauses:
            rendu["pauses"] = (f"{len(pauses)} pause{'s' if len(pauses) > 1 else ''}, "
                               f"{chrono(sum(p['duree_s'] for p in pauses))} en tout")
    elif len(etapes) > 1 and not rendu["fractions"]:
        rendu["etapes"] = f"{len(etapes)} étapes"
    if detail.get("fc_recuperation"):
        rendu["fc_recuperation"] = f"−{detail['fc_recuperation']} bpm une minute après l'arrêt"
    return {cle: v for cle, v in rendu.items() if v not in (None, "", [])}


def avec_la_meteo(u: int, detail: dict, rendu: dict) -> dict:
    """MTO-8 : la météo du départ et le vent sur le parcours, s'il y a un tracé."""
    if detail.get("id_activite") and detail.get("trace"):
        try:
            from api import meteo
            ligne = meteo.en_clair_de_l_activite(meteo.de_l_activite(u, detail["id_activite"]))
            if ligne:
                rendu["meteo"] = ligne
        except Exception:  # noqa: BLE001 - une course se lit aussi sans sa météo
            pass
    return rendu


def course_de_la_seance(u: int, id_occurrence: int) -> dict | None:
    """La course d'une séance, si sa séance de la montre a des mesures."""
    ligne = un_seul("SELECT detail_course(%(u)s, %(o)s) AS d", {"u": u, "o": id_occurrence})
    detail = ligne and ligne["d"]
    if not detail or detail.get("discipline") != "course" or len(detail.get("courbe") or []) < 2:
        return None
    return avec_la_meteo(u, detail, en_clair(detail))


def courses(u: int, du: date, au: date, nombre: int, complet: bool) -> list[dict]:
    """Les courses de la période qui ont des mesures, de la plus récente à la plus ancienne."""
    ids = lister(
        """SELECT a.id_activite FROM activite_sante a
            WHERE a.id_utilisateur = %(u)s AND a.doublon_de IS NULL AND a.discipline = 'course'
              AND jour_de(lower(a.periode)) BETWEEN %(du)s AND %(au)s
              AND EXISTS (SELECT 1 FROM activite_serie s WHERE s.id_activite = a.id_activite)
            ORDER BY lower(a.periode) DESC LIMIT %(n)s""",
        {"u": u, "du": du, "au": au, "n": nombre})
    rendu = []
    for x in ids:
        ligne = un_seul("SELECT detail_activite(%(u)s, %(a)s) AS d",
                        {"u": u, "a": x["id_activite"]})
        if ligne and ligne["d"]:
            rendu.append(avec_la_meteo(u, ligne["d"], en_clair(ligne["d"], complet)))
    return rendu


def periode(a: dict, jours_par_defaut: int = 42) -> tuple[date, date]:
    au = date.fromisoformat(a["au"]) if a.get("au") else aujourd_hui()
    du = date.fromisoformat(a["du"]) if a.get("du") else au - timedelta(days=jours_par_defaut - 1)
    return du, au

