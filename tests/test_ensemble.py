"""Les tâches qui vont ensemble            (TAC-14 à TAC-19, PLA-14, PLA-15, ABS-8)

Jusqu'ici chaque tâche se plaçait seule. Le planning proposait le même jour un
ramassage de litière et son vidage complet, un récurage sans aspirateur avant,
et il fallait cocher la poussière pour qu'un aspirateur apparaisse le lendemain.

Ces tests décrivent les liens : ce qui en couvre une autre, ce qui en accompagne
une autre, ce qui suit, ce qu'on fait en partant et en rentrant. Et ce que
l'absence de l'un ne doit pas coûter à l'autre.
"""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg
import pytest

from api import conversation as conv
from api.ordonnanceur import placer
from tests.conftest import _url

PARIS = ZoneInfo("Europe/Paris")
OUVERTS = "('a_placer', 'planifiee', 'notifiee')"


def sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row,
                         autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def un(requete: str, *parametres):
    lignes = sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def _id(pseudo: str) -> int:
    return un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)


def minuit(dans_jours: int) -> datetime:
    return (datetime.now(PARIS) + timedelta(days=dans_jours)).replace(
        hour=0, minute=0, second=0, microsecond=0)


def prevues(code: str) -> list[dict]:
    """Les occurrences placées d'une tâche, dans l'ordre du calendrier."""
    return sql(f"""
        SELECT o.id_occurrence, u.pseudo, o.titre, o.origine, o.statut, o.motif,
               jour_de(lower(o.creneau)) AS jour
          FROM occurrence o
          JOIN tache t USING (id_tache)
          LEFT JOIN utilisateur u USING (id_utilisateur)
         WHERE t.code = %s AND o.creneau IS NOT NULL AND o.statut IN {OUVERTS}
         ORDER BY lower(o.creneau), o.id_occurrence""", code)


def jours(code: str) -> list:
    return [o["jour"] for o in prevues(code)]


def cours_tous_les_jours(pseudos=("thomas", "lorette"), pendant: int = 45) -> None:
    """Plus aucune journée libre : c'est le cas ordinaire d'une semaine de fac."""
    for pseudo in pseudos:
        for j in range(pendant):
            debut = minuit(j).replace(hour=9)
            sql("INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode) "
                "SELECT %s, id_source, 'cours', 'Cours', tstzrange(%s, %s, '[)') "
                "  FROM source ORDER BY id_source LIMIT 1",
                _id(pseudo), debut, debut + timedelta(hours=2))


def absent(pseudo: str, debut: datetime, fin: datetime) -> None:
    sql("INSERT INTO absence (id_utilisateur, periode, lieu, origine) "
        "VALUES (%s, tstzrange(%s, %s, '[)'), 'Lusse', 'manuelle')",
        _id(pseudo), debut, fin)


def valider(code: str, pseudo: str = "thomas") -> int:
    numero = un(f"""
        SELECT o.id_occurrence FROM occurrence o JOIN tache t USING (id_tache)
         WHERE t.code = %s AND o.statut IN {OUVERTS}
         ORDER BY lower(COALESCE(o.creneau, o.fenetre)) LIMIT 1""", code)
    sql("SELECT valider_occurrence(%s, %s, NULL)", numero, _id(pseudo))
    return numero


# ---------------------------------------------------------------------------
# Le vidage vaut ramassage, dès le planning                             TAC-19
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("couvre, couverte", [
    ("LITIERE_VIDAGE", "LITIERE_CROTTES"),
    ("FONTAINE_SASSY", "EAU_SASSY"),
])
def test_pas_de_ramassage_le_jour_du_vidage(base, couvre, couverte):
    placer()

    communs = set(jours(couvre)) & set(jours(couverte))

    assert jours(couvre), "la tâche qui couvre doit être au planning"
    assert jours(couverte), "et celle qu'elle couvre aussi, les autres jours"
    assert communs == set(), f"les deux le même jour : {sorted(communs)}"


def _vidage_aujourd_hui() -> None:
    """Le prochain vidage est dû aujourd'hui."""
    sql(f"""UPDATE occurrence SET fenetre = tstzrange(%s, %s, '[)'),
                                  creneau = tstzrange(%s, %s, '[)')
             WHERE id_occurrence = (
                   SELECT o.id_occurrence FROM occurrence o JOIN tache t USING (id_tache)
                    WHERE t.code = 'LITIERE_VIDAGE' AND o.statut IN {OUVERTS}
                    ORDER BY lower(o.fenetre) LIMIT 1)""",
        minuit(0), minuit(1), minuit(0), minuit(1))


def test_un_ramassage_oublie_s_efface_quand_le_vidage_arrive(base):
    """« Si on oublie, et qu'après c'est le nettoyage complet, le ramassage s'efface. »"""
    placer()
    _vidage_aujourd_hui()
    oublie = un("""
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine, nb_relances)
        SELECT id_tache, %s, tstzrange(%s, %s, '[)'), 'notifiee', 'recurrence', 1
          FROM tache WHERE code = 'LITIERE_CROTTES'
        RETURNING id_occurrence""", _id("lorette"), minuit(-1), minuit(0))
    placer()

    restee = sql("SELECT statut, motif FROM occurrence WHERE id_occurrence = %s", oublie)[0]
    # Elle avait été annoncée : elle est close, avec sa raison, et non effacée.
    assert restee["statut"] == "abandonnee"
    assert restee["motif"] == "Couverte par « Litière : vidage complet »"


def test_un_ramassage_en_retard_reste_si_le_vidage_est_loin(base):
    placer()
    valider("LITIERE_VIDAGE")
    placer()
    assert jours("LITIERE_VIDAGE")[0] > minuit(3).date(), "le prochain vidage est loin"
    en_retard = un("""
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine, nb_relances)
        SELECT id_tache, %s, tstzrange(%s, %s, '[)'), 'notifiee', 'recurrence', 1
          FROM tache WHERE code = 'LITIERE_CROTTES'
        RETURNING id_occurrence""", _id("lorette"), minuit(-1), minuit(0))

    placer()

    # D'ici le vidage, les crottes restent à ramasser.
    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", en_retard) == "notifiee"


def test_cocher_le_vidage_ne_coche_pas_les_ramassages_du_mois(base):
    """Le défaut que le journal a fait voir.

    Valider un vidage marquait « faites » toutes les occurrences ouvertes du
    ramassage, prévisions comprises : douze ramassages faits d'un coup, jusqu'au
    mois suivant.
    """
    placer()

    valider("LITIERE_VIDAGE")

    faits = un("""SELECT count(*) FROM occurrence o JOIN tache t USING (id_tache)
                   WHERE t.code = 'LITIERE_CROTTES' AND o.statut = 'faite'""")
    assert faits <= 1
    # Et le prochain ramassage repart du jour du vidage : dans deux jours.
    suivant = un(f"""SELECT min(jour_de(lower(o.fenetre))) FROM occurrence o
                      JOIN tache t USING (id_tache)
                     WHERE t.code = 'LITIERE_CROTTES' AND o.statut IN {OUVERTS}""")
    assert suivant == minuit(2).date()


def test_le_tour_n_est_pas_fausse_par_un_ramassage_retire(base):
    placer()

    suite = [o["pseudo"] for o in prevues("LITIERE_CROTTES")]

    # Le ramassage du jour du vidage part avant d'avoir été attribué : ses
    # deux voisins ne reviennent donc pas à la même personne.
    doubles = [i for i in range(1, len(suite)) if suite[i] == suite[i - 1]]
    assert not doubles, suite


# ---------------------------------------------------------------------------
# L'aspirateur accompagne                                               TAC-15
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("mene, mention", [
    ("RECURAGE", "avant de récurer"),
    ("POUSSIERE", "après la poussière"),
])
def test_l_aspirateur_vient_le_meme_jour_pour_la_meme_personne(base, mene, mention):
    cours_tous_les_jours()
    placer()

    aspirateurs = {(o["jour"], o["pseudo"]): o for o in prevues("ASPIRATEUR")}

    menees = prevues(mene)
    assert menees
    for occurrence in menees:
        cle = (occurrence["jour"], occurrence["pseudo"])
        assert cle in aspirateurs, f"{mene} sans aspirateur le {occurrence['jour']}"
        # TAC-16 : son titre dit ce qu'il accompagne. Poussière et récurage le
        # même jour partagent le leur, qui dit les deux.
        titre = aspirateurs[cle]["titre"]
        assert titre.startswith("Passer l'aspirateur (") and mention in titre, titre


def test_poussiere_et_recurage_le_meme_jour_partagent_un_aspirateur_qui_dit_les_deux(base):
    cours_tous_les_jours()
    placer()
    recurage = prevues("RECURAGE")[0]
    poussiere = prevues("POUSSIERE")[0]
    debut = minuit((recurage["jour"] - minuit(0).date()).days)
    sql("UPDATE occurrence SET id_utilisateur = %s, "
        "fenetre = tstzrange(%s, %s::TIMESTAMPTZ + INTERVAL '1 day', '[)'), "
        "creneau = tstzrange(%s, %s::TIMESTAMPTZ + INTERVAL '1 day', '[)') "
        "WHERE id_occurrence = %s",
        _id(recurage["pseudo"]), debut, debut, debut, debut, poussiere["id_occurrence"])

    sql("SELECT poser_les_accompagnements()")

    (aspirateur,) = [o for o in prevues("ASPIRATEUR")
                     if (o["jour"], o["pseudo"]) == (recurage["jour"], recurage["pseudo"])]
    # Dans l'ordre de la journée, et le même titre à chaque passe.
    assert aspirateur["titre"] == "Passer l'aspirateur (après la poussière, avant de récurer)"


def test_c_est_l_aspirateur_le_plus_proche_qui_se_deplace(base):
    cours_tous_les_jours()
    placer()

    par_jour = [(o["jour"], o["pseudo"]) for o in prevues("ASPIRATEUR")]

    # Jamais deux aspirateurs le même jour pour la même personne : celui qui
    # était prévu à côté a été déplacé, on n'en a pas ajouté un par-dessus.
    assert len(par_jour) == len(set(par_jour))
    # Et il en reste qui n'accompagnent rien : l'aspirateur garde sa propre
    # cadence entre deux ménages.
    assert any(o["titre"] is None for o in prevues("ASPIRATEUR"))


def test_cocher_la_poussiere_ne_cree_plus_d_aspirateur_apres_coup(base):
    cours_tous_les_jours()
    placer()
    avant = len(prevues("ASPIRATEUR")) + un(
        "SELECT count(*) FROM occurrence o JOIN tache t USING (id_tache) "
        " WHERE t.code = 'ASPIRATEUR' AND o.statut = 'a_placer'")

    valider("POUSSIERE")

    apres = un(f"SELECT count(*) FROM occurrence o JOIN tache t USING (id_tache) "
               f" WHERE t.code = 'ASPIRATEUR' AND o.statut IN {OUVERTS}")
    assert apres == avant


# ---------------------------------------------------------------------------
# Le bloc « Nettoyage », un jour sans cours ni travail                  TAC-17
# ---------------------------------------------------------------------------

def test_un_jour_libre_reunit_poussiere_aspirateur_et_recurage(base):
    # Aucun cours : toutes les journées sont libres.
    placer()

    recurage = prevues("RECURAGE")[0]
    du_jour = sql("""
        SELECT o.titre FROM occurrence o JOIN tache t USING (id_tache)
          JOIN utilisateur u USING (id_utilisateur)
         WHERE jour_de(lower(o.creneau)) = %s AND u.pseudo = %s
           AND t.code IN ('POUSSIERE', 'ASPIRATEUR', 'RECURAGE')
         ORDER BY o.titre""", recurage["jour"], recurage["pseudo"])

    assert [o["titre"] for o in du_jour] == [
        "Nettoyage 1/3 : Faire la poussière",
        "Nettoyage 2/3 : Passer l'aspirateur",
        "Nettoyage 3/3 : Récurer",
    ]


def test_le_bloc_se_lit_dans_l_ordre_au_planning(client, thomas):
    client.post("/planning/placer", headers=thomas)
    qui = prevues("RECURAGE")[0]

    texte = conv.planning_du_jour(_id(qui["pseudo"]),
                                  (qui["jour"] - minuit(0).date()).days)

    positions = [texte.index(f"Nettoyage {rang}/3") for rang in (1, 2, 3)]
    assert positions == sorted(positions)


def test_un_jour_de_cours_ne_forme_pas_de_bloc(base):
    cours_tous_les_jours()

    placer()

    assert un("SELECT count(*) FROM occurrence WHERE titre LIKE 'Nettoyage%'") == 0


def test_un_cours_ajoute_defait_le_bloc(base):
    placer()
    assert un("SELECT count(*) FROM occurrence WHERE titre LIKE 'Nettoyage%'") > 0

    cours_tous_les_jours()
    placer()

    # Les titres se refont à chaque placement : plus de bloc, mais l'aspirateur
    # dit toujours ce qu'il accompagne.
    assert un("SELECT count(*) FROM occurrence WHERE titre LIKE 'Nettoyage%'") == 0
    assert un("SELECT count(*) FROM occurrence WHERE titre LIKE 'Passer l''aspirateur (%'") > 0


def test_on_n_avance_pas_une_tache_qui_vient_d_etre_faite(base):
    placer()
    valider("POUSSIERE")
    placer()

    # Faite aujourd'hui, la poussière ne revient pas dans trois jours au motif
    # qu'un récurage tombe un jour libre.
    assert jours("POUSSIERE")[0] >= minuit(5).date()


# ---------------------------------------------------------------------------
# Placer deux fois ne change rien
# ---------------------------------------------------------------------------

def test_le_planning_ne_bouge_pas_d_un_placement_a_l_autre(base):
    def cliche():
        return sql(f"""SELECT id_occurrence, id_utilisateur, creneau, titre, statut
                         FROM occurrence WHERE statut IN {OUVERTS}
                          AND lower(fenetre) < now() + INTERVAL '30 days'
                        ORDER BY id_occurrence""")

    placer()
    placer()
    premier = cliche()
    placer()

    # Les accompagnements déplacent des tâches après le placement. Si le
    # placement suivant les remettait ailleurs, le planning oscillerait.
    assert cliche() == premier


# ---------------------------------------------------------------------------
# Vider le lave-vaisselle                                               TAC-14
# ---------------------------------------------------------------------------

def test_le_lave_vaisselle_lance_se_vide_le_lendemain(base):
    placer()
    assert prevues("VIDER_LAVE_VAISSELLE") == [], "rien à vider tant qu'il n'est pas lancé"

    sql("SELECT valider_occurrence(%s, %s, %s)",
        un(f"""SELECT o.id_occurrence FROM occurrence o JOIN tache t USING (id_tache)
                WHERE t.code = 'LAVE_VAISSELLE' AND o.statut IN {OUVERTS}
                ORDER BY lower(o.fenetre) LIMIT 1"""),
        _id("thomas"),
        # Lancé hier à 22 heures.
        minuit(-1).replace(hour=22))
    placer()

    (vider,) = prevues("VIDER_LAVE_VAISSELLE")
    assert vider["jour"] == minuit(0).date()
    # Au roulement habituel : quelqu'un l'a, peu importe qui a lancé.
    assert vider["pseudo"] in ("thomas", "lorette")


# ---------------------------------------------------------------------------
# En partant                                                            TAC-18
# ---------------------------------------------------------------------------

def _de_depart() -> dict[str, dict]:
    return {ligne["code"]: ligne for ligne in sql("""
        SELECT t.code, u.pseudo, o.statut FROM occurrence o
          JOIN tache t USING (id_tache) LEFT JOIN utilisateur u USING (id_utilisateur)
         WHERE o.origine = 'depart'""")}


def test_le_dernier_a_partir_ferme_l_appartement(base):
    # Lorette part jeudi soir, Thomas vendredi midi : c'est lui le dernier.
    vendredi = minuit(9).replace(hour=12)
    absent("lorette", vendredi - timedelta(hours=18), vendredi + timedelta(days=3))
    absent("thomas", vendredi, vendredi + timedelta(days=3))

    placer()

    taches = _de_depart()
    assert set(taches) == {"POUBELLES", "LAVE_VAISSELLE", "LITIERE_VIDAGE"}
    assert {t["pseudo"] for t in taches.values()} == {"thomas"}


def test_partis_ensemble_les_taches_se_repartissent(base):
    depart = minuit(9).replace(hour=12)
    absent("lorette", depart, depart + timedelta(days=3))
    absent("thomas", depart, depart + timedelta(days=3))

    placer()

    assert all(t["pseudo"] is not None for t in _de_depart().values())


def test_c_est_une_tache_en_plus_meme_faite_deux_jours_avant(base):
    placer()
    depart = minuit(9).replace(hour=12)
    absent("lorette", depart, depart + timedelta(days=3))
    absent("thomas", depart, depart + timedelta(days=3))
    # La caisse a été changée deux jours avant le départ.
    sql("""INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine, date_faite)
           SELECT id_tache, %s, tstzrange(%s, %s, '[)'), 'faite', 'manuelle', now()
             FROM tache WHERE code = 'LITIERE_VIDAGE'""",
        _id("thomas"), minuit(-1), minuit(0))

    placer()

    # On la refait quand même en partant, pour être tranquille au retour.
    assert "LITIERE_VIDAGE" in _de_depart()


def test_ce_qu_on_fait_en_partant_ne_compte_pas_dans_la_balance(base):
    vendredi = minuit(9).replace(hour=12)
    absent("lorette", vendredi - timedelta(hours=18), vendredi + timedelta(days=3))
    absent("thomas", vendredi, vendredi + timedelta(days=3))
    placer()
    avec = un("SELECT charge_domestique(%s)", _id("thomas"))

    sql("DELETE FROM occurrence WHERE origine = 'depart'")

    # Retirer les trois tâches de départ ne change pas sa charge : elles
    # venaient en plus du roulement.
    assert un("SELECT charge_domestique(%s)", _id("thomas")) == avec


# ---------------------------------------------------------------------------
# En rentrant                                                            ABS-8
# ---------------------------------------------------------------------------

def _au_retour() -> list[dict]:
    return sql("""
        SELECT t.code, u.pseudo, jour_de(lower(o.fenetre)) AS jour
          FROM occurrence o JOIN tache t USING (id_tache)
          LEFT JOIN utilisateur u USING (id_utilisateur)
         WHERE o.origine = 'retour'""")


def test_apres_plus_de_deux_jours_on_change_l_eau_en_rentrant(base):
    depart = minuit(9).replace(hour=12)
    # Thomas rentre le premier, Lorette le lendemain.
    absent("thomas", depart, depart + timedelta(days=3))
    absent("lorette", depart, depart + timedelta(days=4))

    placer()

    (eau,) = _au_retour()
    assert eau["code"] == "EAU_SASSY"
    assert eau["jour"] == (depart + timedelta(days=3)).astimezone(PARIS).date()
    assert eau["pseudo"] == "thomas"


def test_une_absence_courte_ne_demande_rien_au_retour(base):
    depart = minuit(9).replace(hour=12)
    absent("thomas", depart, depart + timedelta(days=1, hours=12))
    absent("lorette", depart, depart + timedelta(days=1, hours=12))

    placer()

    assert _au_retour() == []


def test_un_seul_absent_ne_demande_rien_au_retour(base):
    # Lorette est restée : l'eau a été changée comme d'habitude.
    depart = minuit(9).replace(hour=12)
    absent("thomas", depart, depart + timedelta(days=5))

    placer()

    assert _au_retour() == []


def test_un_retour_tard_le_soir_attend_le_lendemain(base):
    depart = minuit(9).replace(hour=12)
    retour = minuit(12).replace(hour=22, minute=30)
    absent("thomas", depart, retour)
    absent("lorette", depart, retour)

    placer()

    assert _au_retour()[0]["jour"] == minuit(13).date()


def test_replacer_ne_double_pas_l_eau_du_retour(base):
    depart = minuit(9).replace(hour=12)
    absent("thomas", depart, depart + timedelta(days=3))
    absent("lorette", depart, depart + timedelta(days=3))

    placer()
    placer()
    placer()

    assert len(_au_retour()) == 1


def test_un_retour_annule_reprend_sa_tache(base):
    depart = minuit(9).replace(hour=12)
    absent("thomas", depart, depart + timedelta(days=3))
    absent("lorette", depart, depart + timedelta(days=3))
    placer()
    assert len(_au_retour()) == 1

    sql("DELETE FROM absence")
    placer()

    assert _au_retour() == []


# ---------------------------------------------------------------------------
# Celui qui reste ne prend pas d'avance, celui qui rentre ne rattrape rien
#                                                                      PLA-15
# ---------------------------------------------------------------------------

def _minutes_par_personne(du: datetime, au: datetime) -> dict[str, int]:
    lignes = sql(f"""
        SELECT u.pseudo, COALESCE(sum(t.duree_minutes), 0)::INTEGER AS minutes
          FROM occurrence o JOIN tache t USING (id_tache)
          JOIN utilisateur u USING (id_utilisateur)
         WHERE o.statut IN {OUVERTS} AND o.creneau IS NOT NULL
           AND t.categorie <> 'sport' AND NOT t.requiert_les_deux
           AND t.id_utilisateur_defaut IS NULL
           AND lower(o.creneau) >= %s AND lower(o.creneau) < %s
         GROUP BY u.pseudo""", du, au)
    return {"thomas": 0, "lorette": 0, **{x["pseudo"]: x["minutes"] for x in lignes}}


def test_les_taches_faites_seule_ne_comptent_pas_dans_la_balance(base):
    absent("thomas", minuit(8), minuit(14))
    placer()

    seule = un(f"""
        SELECT COALESCE(sum(t.duree_minutes), 0) FROM occurrence o JOIN tache t USING (id_tache)
         WHERE o.id_utilisateur = %s AND o.statut IN {OUVERTS}
           AND t.categorie <> 'sport' AND NOT t.requiert_les_deux
           AND lower(o.creneau) >= %s AND lower(o.creneau) < %s""",
               _id("lorette"), minuit(8), minuit(14))
    assert seule > 0, "Lorette a bien des tâches pendant l'absence de Thomas"

    sans = un(f"""
        SELECT COALESCE(sum(t.duree_minutes), 0) FROM occurrence o JOIN tache t USING (id_tache)
         WHERE o.id_utilisateur = %s AND o.statut IN {OUVERTS}
           AND t.categorie <> 'sport' AND NOT t.requiert_les_deux
           AND NOT (lower(COALESCE(o.creneau, o.fenetre)) >= %s
                    AND lower(COALESCE(o.creneau, o.fenetre)) < %s)""",
              _id("lorette"), minuit(8), minuit(14))
    assert un("SELECT charge_domestique(%s)", _id("lorette")) == sans


def test_celui_qui_rentre_ne_rattrape_pas_le_menage(base):
    """« C'est normal que l'autre ait fait des tâches, il vivait là. »

    Avant : la balance comptait les tâches que Lorette ferait seule, la voyait
    débordée, et donnait à Thomas presque tout le ménage de la semaine du retour.
    """
    absent("thomas", minuit(8), minuit(14))
    placer()

    apres = _minutes_par_personne(minuit(14), minuit(24))

    total = apres["thomas"] + apres["lorette"]
    assert total > 0
    # Une répartition ordinaire, à une heure près : celle de n'importe quelle
    # semaine sans absence.
    assert abs(apres["thomas"] - apres["lorette"]) <= 60, apres


def test_le_tour_reprend_la_ou_il_s_etait_arrete(base):
    sql("""INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine, date_faite)
           SELECT id_tache, %s, tstzrange(%s, %s, '[)'), 'faite', 'manuelle', %s
             FROM tache WHERE code = 'DRAPS'""",
        _id("thomas"), minuit(-20), minuit(-19), minuit(-20) + timedelta(hours=10))
    # Thomas absent : Lorette refait les draps, seule.
    absent("thomas", minuit(-10), minuit(-2))
    sql("""INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine, date_faite)
           SELECT id_tache, %s, tstzrange(%s, %s, '[)'), 'faite', 'manuelle', %s
             FROM tache WHERE code = 'DRAPS'""",
        _id("lorette"), minuit(-5), minuit(-4), minuit(-5) + timedelta(hours=10))

    dernier = un("SELECT dernier_a_faire(id_tache) FROM tache WHERE code = 'DRAPS'")

    # Le dernier vrai tour est celui de Thomas, avant son départ. Les draps
    # reviennent donc à Lorette, et non à lui parce qu'il rentre.
    assert dernier == _id("thomas")


# ---------------------------------------------------------------------------
# Les priorités                                                         PLA-14
# ---------------------------------------------------------------------------

def test_les_priorites_revues(base):
    priorites = {x["code"]: x["priorite"] for x in sql("SELECT code, priorite FROM tache")}

    assert priorites["ETENDRE_LINGE"] == 1, "du linge mouillé n'attend pas"
    assert priorites["VIDER_LAVE_VAISSELLE"] == 2
    assert priorites["RECURAGE"] == 3
    # Le récurage emmène l'aspirateur : il se place avant lui.
    assert priorites["RECURAGE"] < priorites["ASPIRATEUR"]
