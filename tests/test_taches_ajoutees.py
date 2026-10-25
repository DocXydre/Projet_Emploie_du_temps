"""Les tâches ajoutées par le foyer                                       (TAC-20)

Un cycle long, ou une chose à faire une fois avant une date. Ce que la base
tient, quel que soit l'écran qui l'ajoute : creer_tache, arreter_tache, et
le report de minuit.
"""

from datetime import timedelta

import psycopg
import pytest

from api.ordonnanceur import placer, report_de_minuit
from tests.test_ensemble import OUVERTS, _id, minuit, sql, un

# ---------------------------------------------------------------------------
# Une tâche régulière : le cycle long
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Une tâche ponctuelle : une fois, avant une date
# ---------------------------------------------------------------------------


def test_une_tache_ponctuelle_ne_s_abandonne_pas_toute_seule(base):
    """Le ménage revient de lui-même, on peut en laisser passer un. Un colis non."""
    numero = un("SELECT creer_tache('Rendre le colis', %s, p_au => %s, p_pour => %s, "
                "p_duree_minutes => 15)",
                _id("thomas"), minuit(0).date(), _id("thomas"))
    # Six jours de retard : au-delà du délai d'abandon des tâches ordinaires.
    sql("""UPDATE occurrence SET fenetre = tstzrange(%s, %s, '[)'), statut = 'planifiee',
                                 creneau = tstzrange(%s, %s, '[)')
            WHERE id_tache = %s""",
        minuit(-7), minuit(-6), minuit(-7), minuit(-6), numero)

    report_de_minuit()

    statuts = {x["statut"] for x in sql("SELECT statut FROM occurrence WHERE id_tache = %s",
                                        numero)}
    assert "abandonnee" not in statuts
    assert statuts & {"a_placer", "planifiee", "notifiee"}, "elle est toujours à faire"


# ---------------------------------------------------------------------------
# Les sorties de route
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("jours, echeance", [(None, None), (7, "2099-01-01")])
def test_reguliere_ou_ponctuelle_pas_les_deux(base, jours, echeance):
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("SELECT creer_tache('Essai', %s, p_tous_les_jours => %s, p_au => %s)",
            _id("thomas"), jours, echeance)


# ---------------------------------------------------------------------------
# Celles qu'on a ajoutées
# ---------------------------------------------------------------------------


def test_une_tache_d_origine_s_arrete_comme_les_autres(base):
    """TAC-29 : elle n'a plus rien de particulier ; elle rejoint les tâches arrêtées."""
    aspirateur = un("SELECT essais.tache_de('ASPIRATEUR')")

    assert un("SELECT arreter_tache(%s)", aspirateur) is True
    assert un("SELECT active FROM tache WHERE id_tache = %s", aspirateur) is False
    assert un("SELECT arretee_le FROM tache WHERE id_tache = %s", aspirateur) is not None


def test_la_tache_ajoutee_entre_au_planning_comme_les_autres(base):
    sql("SELECT creer_tache('Nettoyer le four', %s, p_tous_les_jours => 30, p_duree_minutes => 30)",
        _id("thomas"))

    placer()

    prevue = sql(f"""SELECT o.creneau, o.id_utilisateur FROM occurrence o
                      JOIN tache t USING (id_tache)
                     WHERE t.libelle = 'Nettoyer le four' AND o.statut IN {OUVERTS}
                     ORDER BY lower(o.fenetre) LIMIT 1""")[0]
    assert prevue["creneau"] is not None
    # Jamais faite : due dans le mois qui vient, pas dans trois mois.
    assert prevue["creneau"].lower < minuit(0) + timedelta(days=35)
