"""Ce qu'on fait avant de partir, et ce qu'un voyage change au calendrier.

Les poubelles ont une heure, 17h au plus tôt, réglée dans le formulaire comme
pour toute tâche. Ce qu'elles demandent avant un départ n'est plus une règle du
moteur : c'est leur description, que HAL applique (TAC-29, VER-10, annexe 15).

Et une proposition de week-end ne pose plus la question une fois le billet
acheté : elle devient le week-end (WKD-6).
"""

from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

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


# ---------------------------------------------------------------------------
# Les poubelles ont une heure                                          TAC-13
# ---------------------------------------------------------------------------

def test_les_poubelles_ne_se_sortent_pas_le_matin(client, thomas):
    client.post("/planning/placer", headers=thomas)

    heures = _sql(
        "SELECT lower(o.creneau) AT TIME ZONE 'Europe/Paris' AS quand "
        "  FROM occurrence o JOIN tache t USING (id_tache) "
        " WHERE t.id_tache = essais.tache_de('POUBELLES') AND o.creneau IS NOT NULL")

    assert heures, "aucune sortie de poubelles placée"
    for ligne in heures:
        assert ligne["quand"].hour >= 17, ligne["quand"]


def test_les_poubelles_gardent_leur_echeance(base):
    tache = _sql("SELECT * FROM tache WHERE id_tache = essais.tache_de('POUBELLES')")[0]

    assert tache["rappel_journee"] is False
    # Quatre jours au plus entre deux sorties, comme avant.
    assert tache["periodicite_max_jours"] == 4
    # Le départ est dans la description, pour HAL.
    assert "avant que le dernier parte" in _un(
        "SELECT texte FROM v_description_tache WHERE id_tache = %s", tache["id_tache"])


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
