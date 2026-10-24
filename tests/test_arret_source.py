"""Arrêter de suivre un emploi du temps.                                   (COL-21)

Une démission n'efface pas les mois travaillés : le calendrier doit toujours
dire ce qu'on faisait tel jour. Elle efface en revanche ce qui était prévu.
"""

from datetime import UTC, datetime, timedelta

import psycopg
from icalendar import Calendar

from api import sources
from api.collecteurs.service import sources_a_collecter
from tests.conftest import JETON_THOMAS, _url


def poser(conn, source: str, cle: str, jours: int, type_occupation: str = "travail") -> None:
    debut = (datetime.now(UTC) + timedelta(days=jours)).replace(
        hour=16, minute=0, second=0, microsecond=0)
    conn.execute(
        """
        INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode, cle_externe)
        SELECT u.id_utilisateur, s.id_source, %s, %s, tstzrange(%s, %s, '[)'), %s
          FROM utilisateur u, source s
         WHERE u.pseudo = 'thomas' AND s.code = %s
        """,
        (type_occupation, f"Occupation {cle}", debut, debut + timedelta(hours=4), cle, source),
    )


def occupations(conn, source: str) -> set[str]:
    return {cle for (cle,) in conn.execute(
        "SELECT o.cle_externe FROM occupation o JOIN source s USING (id_source) "
        " WHERE s.code = %s", (source,)).fetchall()}


def planning_mcdo() -> None:
    with psycopg.connect(_url(), autocommit=True) as conn:
        poser(conn, "MCDO", "PASSE", -3)
        poser(conn, "MCDO", "BIENTOT", 2)
        poser(conn, "MCDO", "PLUS_TARD", 5)
        poser(conn, "IDMC_ICS", "COURS", 3, "cours")


# ---------------------------------------------------------------------------

def test_l_avenir_disparait_le_passe_reste(client, thomas):
    planning_mcdo()

    bilan = sources.arreter_source("MCDO")

    assert bilan["occupations_retirees"] == 2
    with psycopg.connect(_url()) as conn:
        assert occupations(conn, "MCDO") == {"PASSE"}
        # Les autres emplois du temps n'ont rien à voir là-dedans.
        assert occupations(conn, "IDMC_ICS") == {"COURS"}


def test_le_passe_reste_dans_le_calendrier_du_telephone(client, thomas):
    planning_mcdo()
    sources.arreter_source("MCDO")

    flux = client.get("/planning.ics", params={"cle": JETON_THOMAS})
    resumes = {str(e["SUMMARY"]) for e in Calendar.from_ical(flux.content).walk("VEVENT")}

    assert any("PASSE" in r for r in resumes)
    assert not any("BIENTOT" in r or "PLUS_TARD" in r for r in resumes)


def test_la_source_arretee_n_est_plus_collectee(client, thomas):
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("UPDATE source SET url = 'https://exemple.fr/shifts.ics' "
                     " WHERE code = 'MCDO'")
    assert "MCDO" in sources_a_collecter()

    sources.arreter_source("mcdo")   # la casse ne compte pas, comme pour /lien

    assert "MCDO" not in sources_a_collecter()
    with psycopg.connect(_url()) as conn:
        assert conn.execute("SELECT active FROM source WHERE code = 'MCDO'").fetchone() \
            == (False,)


def test_une_source_arretee_n_est_pas_signalee_en_panne(client, thomas):
    # Une source jamais collectée paraît en panne. Arrêtée, elle ne doit plus
    # apparaître dans le bilan du matin comme quelque chose à réparer.
    sources.arreter_source("MCDO")

    with psycopg.connect(_url()) as conn:
        en_panne = {code for (code,) in conn.execute(
            "SELECT code FROM v_source_sante WHERE etat_calcule = 'en_panne' AND active")}
    assert "MCDO" not in en_panne


def test_une_source_inconnue_le_dit(base):
    assert sources.arreter_source("BURGER_KING") is None

