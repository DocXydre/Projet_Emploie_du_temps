"""La météo : avant une séance dehors, et après une course          (MTO)

Open-Meteo rend heure par heure la température, le ressenti, la pluie, le vent
et sa direction, à partir des modèles de Météo-France. Gratuit et sans clé.

    1. la prévision d'un point, gardée en base                    (MTO-1)
    2. le point d'une séance                                       (MTO-2)
    3. les seuils fixes d'une heure avant                          (MTO-3)
    4. la météo d'une course, et le vent rapporté au tracé  (MTO-6, MTO-7)
    5. ce que HAL lit                                        (MTO-5, MTO-8)

Rien ne bloque sans réponse d'Open-Meteo (MTO-10) : la fonction rend None, et
celui qui l'appelle fait comme s'il n'avait pas de météo.
"""

import logging
import math
from datetime import UTC, date, datetime, time, timedelta

import httpx

from api.base import executer, lister, un_seul

LOG = logging.getLogger(__name__)

PREVISIONS = "https://api.open-meteo.com/v1/forecast"
ARCHIVES = "https://archive-api.open-meteo.com/v1/archive"
VARIABLES = ("temperature_2m,apparent_temperature,precipitation,precipitation_probability,"
             "wind_speed_10m,wind_gusts_10m,wind_direction_10m,relative_humidity_2m,"
             "weather_code")
DELAI_SECONDES = 8.0
# Open-Meteo garde les prévisions passées trois mois ; au-delà, les archives.
JOURS_DE_PREVISIONS_PASSEES = 90
JOURS_D_AVANCE = 8

# MTO-1 : une prévision relue sert une heure avant une séance, trois ailleurs.
FRAICHEUR_CONTROLE = timedelta(hours=1)
FRAICHEUR = timedelta(hours=3)

# MTO-3, annexe 3 : les seuils fixes.
PLUIE_MM = 0.5
PLUIE_PROBABLE_POURCENT = 70
PLUIE_PROBABLE_MM = 0.2
RESSENTI_GEL = 0.0
VENT_KMH = 40.0
RAFALES_KMH = 60.0
CANICULE = 30.0

# MTO-7 : face sous 45°, dos au-delà de 135°, et pas sous 10 km/h.
ANGLE_FACE = 45.0
ANGLE_DOS = 135.0
VENT_FAIBLE_KMH = 10.0


def _arrondi(x) -> float:
    return round(float(x), 2)


def _heure(instant: datetime) -> datetime:
    return instant.astimezone(UTC).replace(minute=0, second=0, microsecond=0)


# ---------------------------------------------------------------------------
# 1. Les prévisions                                                   (MTO-1)
# ---------------------------------------------------------------------------

def _interroger(url: str, params: dict) -> list[dict] | None:
    """Les heures rendues par Open-Meteo, ou None s'il ne répond pas."""
    try:
        reponse = httpx.get(url, params={**params, "hourly": VARIABLES, "timezone": "UTC",
                                         "wind_speed_unit": "kmh"},
                            timeout=DELAI_SECONDES)
        reponse.raise_for_status()
        h = reponse.json()["hourly"]
    except (httpx.HTTPError, ValueError, KeyError) as erreur:
        LOG.info("Open-Meteo ne répond pas : %s", erreur)
        return None

    def col(nom, i):
        valeurs = h.get(nom) or []
        return valeurs[i] if i < len(valeurs) else None

    return [{"heure": datetime.fromisoformat(t).replace(tzinfo=UTC),
             "temperature": col("temperature_2m", i), "ressenti": col("apparent_temperature", i),
             "pluie_mm": col("precipitation", i),
             "pluie_proba": col("precipitation_probability", i),
             "vent_kmh": col("wind_speed_10m", i), "rafales_kmh": col("wind_gusts_10m", i),
             "direction_deg": col("wind_direction_10m", i),
             "humidite": col("relative_humidity_2m", i), "code_temps": col("weather_code", i)}
            for i, t in enumerate(h.get("time") or [])]


def _garder(lat: float, lon: float, heures: list[dict]) -> None:
    for x in heures:
        executer(
            """INSERT INTO meteo_heure (latitude, longitude, heure, temperature, ressenti,
                                        pluie_mm, pluie_proba, vent_kmh, rafales_kmh,
                                        direction_deg, humidite, code_temps, releve_le)
               VALUES (%(la)s, %(lo)s, %(heure)s, %(temperature)s, %(ressenti)s,
                       %(pluie_mm)s, %(pluie_proba)s, %(vent_kmh)s, %(rafales_kmh)s,
                       %(direction_deg)s, %(humidite)s, %(code_temps)s, now())
               ON CONFLICT (latitude, longitude, heure) DO UPDATE
                  SET temperature = EXCLUDED.temperature, ressenti = EXCLUDED.ressenti,
                      pluie_mm = EXCLUDED.pluie_mm, pluie_proba = EXCLUDED.pluie_proba,
                      vent_kmh = EXCLUDED.vent_kmh, rafales_kmh = EXCLUDED.rafales_kmh,
                      direction_deg = EXCLUDED.direction_deg, humidite = EXCLUDED.humidite,
                      code_temps = EXCLUDED.code_temps, releve_le = now()""",
            {**x, "la": lat, "lo": lon})


def prevision(latitude, longitude, debut: datetime, fin: datetime,
              fraicheur: timedelta = FRAICHEUR) -> list[dict] | None:
    """Les heures de debut à fin (exclue), en base si elles sont fraîches, sinon
    relues chez Open-Meteo et gardées. None si Open-Meteo ne répond pas."""
    lat, lon = _arrondi(latitude), _arrondi(longitude)
    premiere, derniere = _heure(debut), _heure(fin - timedelta(seconds=1))
    attendues = int((derniere - premiere).total_seconds() // 3600) + 1
    lignes = lister(
        """SELECT heure, temperature, ressenti, pluie_mm, pluie_proba, vent_kmh, rafales_kmh,
                  direction_deg, humidite, code_temps
             FROM meteo_heure
            WHERE latitude = %(la)s AND longitude = %(lo)s
              AND heure BETWEEN %(d)s AND %(f)s AND releve_le > now() - %(fr)s
            ORDER BY heure""",
        {"la": lat, "lo": lon, "d": premiere, "f": derniere, "fr": fraicheur})
    if len(lignes) >= attendues:
        return lignes
    heures = _interroger(PREVISIONS, {"latitude": lat, "longitude": lon,
                                      "forecast_days": JOURS_D_AVANCE, "past_days": 1})
    if heures is None:
        return None
    _garder(lat, lon, heures)
    return [x for x in heures if premiere <= x["heure"] <= derniere]


def passee(latitude, longitude, instant: datetime) -> dict | None:
    """La météo d'une heure passée : prévisions passées jusqu'à 90 jours, archives
    au-delà (MTO-6)."""
    jour = instant.astimezone(UTC).date()
    recent = (datetime.now(UTC).date() - jour).days <= JOURS_DE_PREVISIONS_PASSEES
    heures = _interroger(PREVISIONS if recent else ARCHIVES,
                         {"latitude": _arrondi(latitude), "longitude": _arrondi(longitude),
                          "start_date": jour.isoformat(), "end_date": jour.isoformat()})
    if not heures:
        return None
    cible = _heure(instant)
    return next((x for x in heures if x["heure"] == cible), None)


# ---------------------------------------------------------------------------
# 2. Le point d'une séance                                            (MTO-2)
# ---------------------------------------------------------------------------

def seances_dehors(id_utilisateur: int | None, du: datetime, au: datetime) -> list[dict]:
    """Les séances dehors qui commencent entre du et au, avec leur point."""
    return lister(
        """SELECT o.id_occurrence, o.id_utilisateur, o.debut_seance AS debut,
                  COALESCE(se.duree_minutes, ls.duree_minutes, 60) AS duree_minutes,
                  ls.libelle AS lieu, se.etat, se.type_seance, se.discipline,
                  COALESCE(lc.latitude, d.latitude) AS latitude,
                  COALESCE(lc.longitude, d.longitude) AS longitude,
                  COALESCE(lc.nom, d.nom) AS point
             FROM occurrence o
             JOIN lieu_sport ls ON ls.id_lieu = o.id_lieu AND ls.dehors
             LEFT JOIN seance se ON se.id_occurrence = o.id_occurrence
             LEFT JOIN lieu_connu lc ON lc.id_lieu_connu = ls.id_lieu_connu
             LEFT JOIN lieu_connu d
                    ON d.id_lieu_connu = lieu_ou_l_on_sera(o.id_utilisateur,
                                                           jour_de(o.debut_seance))
            WHERE o.debut_seance >= %(du)s AND o.debut_seance < %(au)s
              AND o.statut IN ('planifiee', 'notifiee')
              AND (%(u)s::INTEGER IS NULL OR o.id_utilisateur = %(u)s)
            ORDER BY o.debut_seance""",
        {"u": id_utilisateur, "du": du, "au": au})


def pendant(seance: dict, fraicheur: timedelta = FRAICHEUR) -> list[dict] | None:
    """La prévision sur la durée d'une séance, ou None sans point ni réponse."""
    if seance.get("latitude") is None:
        return None
    debut = seance["debut"]
    fin = debut + timedelta(minutes=int(seance.get("duree_minutes") or 60))
    return prevision(seance["latitude"], seance["longitude"], debut, fin, fraicheur)


# ---------------------------------------------------------------------------
# 3. Les seuils d'une heure avant                                     (MTO-3)
# ---------------------------------------------------------------------------

def _n(x) -> float | None:
    return None if x is None else float(x)


def seuils_franchis(heures: list[dict]) -> list[str]:
    """Ce que la prévision franchit, en clair, une fois chaque seuil."""
    franchis = []
    pluie = max((_n(h["pluie_mm"]) or 0 for h in heures), default=0)
    probable = any((h.get("pluie_proba") or 0) >= PLUIE_PROBABLE_POURCENT
                   and (_n(h["pluie_mm"]) or 0) >= PLUIE_PROBABLE_MM for h in heures)
    if pluie >= PLUIE_MM or probable:
        franchis.append(f"pluie : jusqu'à {pluie:.1f} mm dans l'heure".replace(".", ","))
    ressentis = [_n(h["ressenti"]) for h in heures if h.get("ressenti") is not None]
    if ressentis and min(ressentis) <= RESSENTI_GEL:
        franchis.append(f"gel : ressenti {min(ressentis):.0f} °C")
    vent = max((_n(h["vent_kmh"]) or 0 for h in heures), default=0)
    rafales = max((_n(h["rafales_kmh"]) or 0 for h in heures), default=0)
    if vent >= VENT_KMH or rafales >= RAFALES_KMH:
        franchis.append(f"vent fort : {vent:.0f} km/h, rafales à {rafales:.0f}")
    temperatures = [_n(h["temperature"]) for h in heures if h.get("temperature") is not None]
    if temperatures and max(temperatures) >= CANICULE:
        franchis.append(f"canicule : {max(temperatures):.0f} °C")
    return franchis


DIRECTIONS = ("nord", "nord-est", "est", "sud-est", "sud", "sud-ouest", "ouest", "nord-ouest")


def direction(degres) -> str | None:
    if degres is None:
        return None
    return DIRECTIONS[round(float(degres) / 45) % 8]


def ligne(h: dict) -> str:
    """Une heure en clair, pour HAL."""
    from api.coach.clair import fuseau
    morceaux = [h["heure"].astimezone(fuseau()).strftime("%Hh")]
    if h.get("temperature") is not None:
        morceaux.append(f"{float(h['temperature']):.0f} °C (ressenti "
                        f"{float(h['ressenti']):.0f})" if h.get("ressenti") is not None
                        else f"{float(h['temperature']):.0f} °C")
    pluie = _n(h.get("pluie_mm")) or 0
    morceaux.append(f"pluie {pluie:.1f} mm".replace(".", ",")
                    + (f" ({h['pluie_proba']} %)" if h.get("pluie_proba") is not None else ""))
    if h.get("vent_kmh") is not None:
        morceaux.append(f"vent {float(h['vent_kmh']):.0f} km/h {direction(h['direction_deg'])}"
                        f", rafales {float(h['rafales_kmh'] or 0):.0f}")
    return " · ".join(morceaux)


# ---------------------------------------------------------------------------
# 4. La météo d'une course                                     (MTO-6, MTO-7)
# ---------------------------------------------------------------------------

def _cap(lat1, lon1, lat2, lon2) -> float:
    """Le cap suivi d'un point à l'autre, en degrés depuis le nord."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(p2)
    y = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def _metres(lat1, lon1, lat2, lon2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2)
    return 2 * 6371000 * math.asin(math.sqrt(a))


def vent_sur_le_trace(points: list[dict], provenance_deg: float, vent_kmh: float) -> dict:
    """MTO-7 : les parts face, dos et travers, la composante de face, et l'allure
    de chaque côté. Le vent vient de `provenance_deg` : courir vers lui, c'est
    l'avoir de face."""
    distances = {"face": 0.0, "dos": 0.0, "travers": 0.0}
    secondes = {"face": 0.0, "dos": 0.0}
    composante = 0.0
    total = 0.0
    for a, b in zip(points, points[1:], strict=False):
        la1, lo1, la2, lo2 = (float(a["latitude"]), float(a["longitude"]),
                              float(b["latitude"]), float(b["longitude"]))
        d = _metres(la1, lo1, la2, lo2)
        duree = (b["instant"] - a["instant"]).total_seconds()
        # Un point immobile ou un saut du GPS ne dit rien du cap.
        if d < 3 or duree <= 0 or d / duree > 12:
            continue
        ecart = abs((_cap(la1, lo1, la2, lo2) - provenance_deg + 180) % 360 - 180)
        sorte = "face" if ecart < ANGLE_FACE else "dos" if ecart > ANGLE_DOS else "travers"
        distances[sorte] += d
        if sorte in secondes:
            secondes[sorte] += duree
        composante += math.cos(math.radians(ecart)) * vent_kmh * d
        total += d
    if total < 200:
        return {}

    def allure(sorte):
        km = distances[sorte] / 1000
        return round(secondes[sorte] / km) if km >= 0.2 else None

    return {"part_face": round(distances["face"] / total, 3),
            "part_dos": round(distances["dos"] / total, 3),
            "part_travers": round(distances["travers"] / total, 3),
            "composante_face_kmh": round(composante / total, 1),
            "allure_face_s": allure("face"), "allure_dos_s": allure("dos")}


def de_l_activite(id_utilisateur: int, id_activite: int) -> dict | None:
    """MTO-6 : la météo d'une course dehors, relevée une fois et gardée. None pour
    une activité sans tracé (un tapis), ou quand Open-Meteo ne répond pas."""
    deja = un_seul(
        """SELECT m.* FROM meteo_activite m JOIN activite_sante a USING (id_activite)
            WHERE m.id_activite = %(a)s AND a.id_utilisateur = %(u)s""",
        {"a": id_activite, "u": id_utilisateur})
    if deja:
        return deja
    points = lister(
        """SELECT t.instant, t.latitude, t.longitude FROM activite_trace t
             JOIN activite_sante a USING (id_activite)
            WHERE t.id_activite = %(a)s AND a.id_utilisateur = %(u)s
            ORDER BY t.instant""", {"a": id_activite, "u": id_utilisateur})
    if len(points) < 2:
        return None
    depart = points[0]
    h = passee(depart["latitude"], depart["longitude"], depart["instant"])
    if h is None:
        return None
    vent = _n(h.get("vent_kmh")) or 0
    rapporte = {}
    if vent >= VENT_FAIBLE_KMH and h.get("direction_deg") is not None:
        rapporte = vent_sur_le_trace(points, float(h["direction_deg"]), vent)
    return executer(
        """INSERT INTO meteo_activite (id_activite, temperature, ressenti, humidite, pluie_mm,
                                       vent_kmh, rafales_kmh, direction_deg, code_temps,
                                       part_face, part_dos, part_travers,
                                       composante_face_kmh, allure_face_s, allure_dos_s)
           VALUES (%(a)s, %(temperature)s, %(ressenti)s, %(humidite)s, %(pluie_mm)s,
                   %(vent_kmh)s, %(rafales_kmh)s, %(direction_deg)s, %(code_temps)s,
                   %(part_face)s, %(part_dos)s, %(part_travers)s, %(composante_face_kmh)s,
                   %(allure_face_s)s, %(allure_dos_s)s)
           ON CONFLICT (id_activite) DO UPDATE SET releve_le = now()
           RETURNING *""",
        {"a": id_activite, **{k: h.get(k) for k in (
            "temperature", "ressenti", "humidite", "pluie_mm", "vent_kmh", "rafales_kmh",
            "direction_deg", "code_temps")},
         **{k: rapporte.get(k) for k in (
             "part_face", "part_dos", "part_travers", "composante_face_kmh",
             "allure_face_s", "allure_dos_s")}})


def en_clair_de_l_activite(m: dict | None) -> str | None:
    """MTO-8 : la ligne météo d'une course, pour HAL."""
    if not m:
        return None
    from api.coach.lecture_courses import allure
    morceaux = []
    if m.get("temperature") is not None:
        morceaux.append(f"{float(m['temperature']):.0f} °C"
                        + (f", ressenti {float(m['ressenti']):.0f}"
                           if m.get("ressenti") is not None else ""))
    if m.get("humidite") is not None:
        morceaux.append(f"humidité {m['humidite']} %")
    if m.get("pluie_mm"):
        morceaux.append(f"pluie {float(m['pluie_mm']):.1f} mm".replace(".", ","))
    if m.get("vent_kmh") is not None:
        vent = float(m["vent_kmh"])
        if vent < VENT_FAIBLE_KMH:
            morceaux.append(f"vent faible ({vent:.0f} km/h)")
        else:
            morceaux.append(f"vent {vent:.0f} km/h de {direction(m['direction_deg'])}")
    if m.get("part_face") is not None:
        morceaux.append(f"{float(m['part_face']) * 100:.0f} % du parcours face au vent, "
                        f"{float(m['part_dos']) * 100:.0f} % dos au vent, composante "
                        f"moyenne de face {float(m['composante_face_kmh']):+.0f} km/h")
        if m.get("allure_face_s") and m.get("allure_dos_s"):
            morceaux.append(f"allure {allure(m['allure_face_s'])} face au vent, "
                            f"{allure(m['allure_dos_s'])} dos au vent")
    return " · ".join(morceaux) or None


# ---------------------------------------------------------------------------
# 5. Ce que HAL lit                                            (MTO-4, MTO-5)
# ---------------------------------------------------------------------------

def debut_du_jour(jour: date) -> datetime:
    from api.coach.clair import fuseau
    return datetime.combine(jour, time(0), fuseau())


def journee(latitude, longitude, jour: date, depuis: datetime | None = None) -> list[str] | None:
    """La prévision d'une journée, heure par heure de 7 h à 22 h, en clair."""
    debut = debut_du_jour(jour) + timedelta(hours=7)
    if depuis and depuis > debut:
        debut = depuis
    fin = debut_du_jour(jour) + timedelta(hours=22)
    if fin <= debut:
        return []
    heures = prevision(latitude, longitude, debut, fin)
    return None if heures is None else [ligne(h) for h in heures]


def texte_du_lendemain(id_utilisateur: int) -> str | None:
    """MTO-5 : pour la synthèse et la révision, la prévision de chaque séance
    dehors de demain, à son heure."""
    from api.coach.clair import aujourd_hui, clair
    demain = aujourd_hui() + timedelta(days=1)
    seances = seances_dehors(id_utilisateur, debut_du_jour(demain),
                             debut_du_jour(demain + timedelta(days=1)))
    if not seances:
        return None
    lignes = ["## Météo des séances dehors de demain (MTO-5)"]
    for s in seances:
        heures = pendant(s)
        titre = (f"- Séance {s['id_occurrence']} ({s['type_seance'] or s['lieu']}), "
                 f"{clair(s['debut'])}")
        if heures is None:
            lignes.append(titre + " : pas de prévision (lieu sans adresse, ou Open-Meteo muet).")
            continue
        franchis = seuils_franchis(heures)
        lignes.append(titre + f", à {s['point']} : "
                      + " | ".join(ligne(h) for h in heures)
                      + (f". Seuils franchis : {', '.join(franchis)}." if franchis else "."))
    lignes.append("Si la météo gêne une séance, tu peux proposer de la changer (ajustement "
                  "sur une séance validée) : l'utilisateur a le dernier mot.")
    return "\n".join(lignes)
