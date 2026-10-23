"""Ce qu'on fait avant de partir, et ce qu'un voyage change au calendrier.

Un appartement vide n'est pas un appartement au repos. Le sac de poubelle qu'on
laisse deux jours se rappelle au retour, et le chat, lui, ne part pas en
week-end. Ces deux tâches-là ne peuvent donc pas attendre (TAC-12).

Deux détails les distinguent. Les poubelles ont une heure, 17h au plus tôt : un
sac sorti le matin passe la journée dehors pour un ramassage qui a lieu à
l'aube (TAC-13). La litière, elle, se fait dans la journée du départ.

Et une proposition de week-end ne pose plus la question une fois le billet
acheté : elle devient le week-end (WKD-6).
"""

from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg
import pytest

from tests.conftest import _url

PARIS = ZoneInfo("Europe/Paris")


def _sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row,
                         autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def _un(requete: str, *parametres):
    lignes = _sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def _vendredi_prochain() -> datetime:
    """Le vendredi de la semaine prochaine, pour sortir de la zone gelée."""
    jour = datetime.now(UTC) + timedelta(days=7)
    while jour.weekday() != 4:
        jour += timedelta(days=1)
    return jour


def _partir(depart: datetime, retour: datetime, pseudos=("thomas", "lorette")) -> None:
    for pseudo in pseudos:
        _sql("INSERT INTO absence (id_utilisateur, periode, lieu, origine) "
             "SELECT id_utilisateur, tstzrange(%s, %s, '[)'), 'Lusse', 'trajet' "
             "  FROM utilisateur WHERE pseudo = %s", depart, retour, pseudo)


def _avant_depart(code: str) -> dict | None:
    lignes = _sql(
        """
        SELECT o.statut, o.motif, u.pseudo,
               lower(o.creneau) AS pose_le, lower(o.fenetre) AS fenetre_debut,
               upper(o.fenetre) AS fenetre_fin
          FROM occurrence o
          JOIN tache t USING (id_tache)
          LEFT JOIN utilisateur u USING (id_utilisateur)
         WHERE t.code = %s AND o.origine = 'depart'
        """, code)
    return lignes[0] if lignes else None


@pytest.fixture
def week_end_a_deux(client, thomas):
    """Les deux partent vendredi 13h03 et rentrent dimanche 10h26."""
    depart = _vendredi_prochain().replace(hour=11, minute=3, second=0, microsecond=0)
    retour = depart + timedelta(days=2, hours=-1)
    _partir(depart, retour)
    client.post("/planning/placer", headers=thomas)
    return depart


# ---------------------------------------------------------------------------
# L'appartement se vide                                                TAC-12
# ---------------------------------------------------------------------------

def test_les_poubelles_sortent_le_dernier_soir(week_end_a_deux):
    poubelles = _avant_depart("POUBELLES")

    assert poubelles is not None, "aucune sortie de poubelles avant le départ"
    assert poubelles["statut"] == "planifiee"
    # Le train part avant 17h : le dernier créneau possible est la veille.
    assert poubelles["pose_le"].astimezone(PARIS).date() \
        == (week_end_a_deux.astimezone(PARIS) - timedelta(days=1)).date()
    assert "Avant de partir" in poubelles["motif"] or poubelles["motif"]


def test_la_litiere_se_vide_le_jour_du_depart(week_end_a_deux):
    # TAC-18 : la caisse est changée en entier, pour que Sassy tienne jusqu'au
    # retour. Le simple ramassage ne figure plus dans la liste.
    litiere = _avant_depart("LITIERE_VIDAGE")

    assert litiere is not None
    assert _avant_depart("LITIERE_CROTTES") is None
    # Le chat reste : la caisse se change le matin même, pas la veille.
    assert litiere["fenetre_debut"].astimezone(PARIS).date() \
        == week_end_a_deux.astimezone(PARIS).date()


def test_les_deux_taches_ont_quelqu_un_pour_les_faire(week_end_a_deux):
    for code in ("POUBELLES", "LITIERE_VIDAGE", "LAVE_VAISSELLE"):
        assert _avant_depart(code)["pseudo"] is not None, code


def test_personne_ne_part_rien_de_special(client, thomas):
    # Thomas s'en va, Lorette reste : c'est elle qui sortira le sac quand il
    # sera plein, et le placement ordinaire s'en charge déjà.
    depart = _vendredi_prochain().replace(hour=11, minute=3, second=0, microsecond=0)
    _partir(depart, depart + timedelta(days=2), pseudos=("thomas",))

    client.post("/planning/placer", headers=thomas)

    assert _avant_depart("POUBELLES") is None
    assert _avant_depart("LITIERE_VIDAGE") is None


def test_replacer_ne_double_pas_les_taches_de_depart(client, thomas, week_end_a_deux):
    client.post("/planning/placer", headers=thomas)
    client.post("/planning/placer", headers=thomas)

    # Les poubelles, le lave-vaisselle et la caisse de Sassy : une de chaque.
    assert _un("SELECT count(*) FROM occurrence WHERE origine = 'depart'") == 3


def test_un_depart_annule_reprend_ses_taches(client, thomas, week_end_a_deux):
    _sql("DELETE FROM absence")

    client.post("/planning/placer", headers=thomas)

    # Plus de départ, plus de corvée d'avant-départ : elle ne doit pas rester
    # plantée dans le planning d'un voyage qui n'a pas lieu.
    assert _un("SELECT count(*) FROM occurrence WHERE origine = 'depart'") == 0


# ---------------------------------------------------------------------------
# Les poubelles ont une heure                                          TAC-13
# ---------------------------------------------------------------------------

def test_les_poubelles_ne_se_sortent_pas_le_matin(client, thomas):
    client.post("/planning/placer", headers=thomas)

    heures = _sql(
        "SELECT lower(o.creneau) AT TIME ZONE 'Europe/Paris' AS quand "
        "  FROM occurrence o JOIN tache t USING (id_tache) "
        " WHERE t.code = 'POUBELLES' AND o.creneau IS NOT NULL")

    assert heures, "aucune sortie de poubelles placée"
    for ligne in heures:
        assert ligne["quand"].hour >= 17, ligne["quand"]


def test_les_poubelles_gardent_leur_echeance(base):
    tache = _sql("SELECT * FROM tache WHERE code = 'POUBELLES'")[0]

    assert tache["rappel_journee"] is False
    assert tache["avant_depart"] is True
    assert tache["reportable"] is False
    # Quatre jours au plus entre deux sorties, comme avant.
    assert tache["periodicite_max_jours"] == 4


# ---------------------------------------------------------------------------
# Le week-end proposé devient le week-end                               WKD-6
# ---------------------------------------------------------------------------

def test_la_proposition_devient_un_week_end(client, thomas):
    depart = _vendredi_prochain().replace(hour=11, minute=3, second=0, microsecond=0)
    _sql("INSERT INTO proposition (id_utilisateur, periode, lieu) "
         "SELECT id_utilisateur, tstzrange(debut_jour(%s::DATE), "
         "                                 debut_jour(%s::DATE + 3), '[)'), 'Lusse' "
         "  FROM utilisateur WHERE pseudo = 'thomas'", depart.date(), depart.date())
    assert _un("SELECT libelle FROM v_planning WHERE nature = 'proposition'") \
        == "Week-end libre à Lusse ?"

    _partir(depart, depart + timedelta(days=2), pseudos=("thomas",))
    client.post("/planning/placer", headers=thomas)

    ligne = _sql("SELECT libelle, statut, categorie, debut, fin FROM v_planning "
                 " WHERE nature = 'proposition'")[0]
    # Elle reste au calendrier, mais elle ne pose plus de question.
    assert ligne["libelle"] == "Week-end à Lusse"
    assert ligne["statut"] == "realisee"
    # Et sans le préfixe « Proposition », qui vient de la catégorie.
    assert ligne["categorie"] != "trajet"
    # WKD-8 : sur les dates du voyage, pas sur celles du creux repéré. Le
    # retour est le dimanche : le lundi n'a rien à faire en week-end.
    assert ligne["debut"] == depart
    assert ligne["fin"] == depart + timedelta(days=2)


def test_un_week_end_confirme_s_arrete_au_train_du_retour(client, thomas):
    # Le creux repéré allait jusqu'au lundi matin ; le billet de retour dit
    # dimanche. C'est le billet qui a raison.
    depart = _vendredi_prochain().replace(hour=11, minute=3, second=0, microsecond=0)
    _sql("INSERT INTO proposition (id_utilisateur, periode, lieu) "
         "SELECT id_utilisateur, tstzrange(debut_jour(%s::DATE), "
         "                                 debut_jour(%s::DATE + 4), '[)'), 'Lusse' "
         "  FROM utilisateur WHERE pseudo = 'thomas'", depart.date(), depart.date())
    _partir(depart, depart + timedelta(days=2), pseudos=("thomas",))

    client.post("/planning/placer", headers=thomas)

    fin = _un("SELECT fin FROM v_planning WHERE nature = 'proposition'")
    assert fin == depart + timedelta(days=2)
    assert fin.astimezone(PARIS).weekday() == 6, "le week-end doit finir dimanche"
