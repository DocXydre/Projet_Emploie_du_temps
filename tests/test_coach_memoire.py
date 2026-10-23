"""Le dossier en paquets, la mémoire en quatre étages, l'importance des échanges.

Aucun appel payant : le choix des paquets par Haiku et les résumés de la
mémoire passent par `modele.ecrire`, remplacé ici par un faux.
"""

# ruff: noqa: F811 (les fixtures de test_coach sont importées puis demandées)

import json
from datetime import date, timedelta
from pathlib import Path

import pytest

from api.coach import aiguillage, appel, dossier, memoire, modele, outils
from api.coach import telegram as coach_tg
from api.coach.clair import aujourd_hui, lundi_de
from api.config import configuration
from api.routeurs import coach as routes
from api.securite import Appelant
from tests.test_coach import (  # noqa: F401
    SEANCE_DU_COACH,
    demande,
    dit,
    faux,
    jour,
    plan,
    question,
    refus,
    u,
)
from tests.test_ensemble import _id, sql, un

RACINE = Path(__file__).resolve().parents[1]


class FausseEcriture:
    """Remplace `modele.ecrire` : rend les textes donnés, dans l'ordre."""

    def __init__(self, *textes):
        self.textes = list(textes)
        self.appels: list[dict] = []

    def __call__(self, systeme, texte, modele_nom, max_tokens, delai):
        self.appels.append({"systeme": systeme, "texte": texte, "modele": modele_nom})
        if not self.textes:
            raise AssertionError("modele.ecrire appelé une fois de trop")
        suivant = self.textes.pop(0)
        if isinstance(suivant, Exception):
            raise suivant
        return modele.Tour(texte=suivant, arret="end_turn", tokens_entree=500,
                           tokens_sortie=80)


@pytest.fixture
def ecrit(monkeypatch):
    def installer(*textes) -> FausseEcriture:
        faux_ecrire = FausseEcriture(*textes)
        monkeypatch.setattr(modele, "ecrire", faux_ecrire)
        return faux_ecrire
    return installer


@pytest.fixture(autouse=True)
def sans_haiku(monkeypatch):
    """Par défaut, Haiku est injoignable : l'aiguillage passe par les mots-clés."""
    def injoignable(*args, **kwargs):
        raise modele.ModeleInjoignable("pas de modèle dans les tests")
    monkeypatch.setattr(modele, "ecrire", injoignable)


def qui(u: int) -> Appelant:
    return Appelant(id_utilisateur=u, pseudo="thomas", role="admin")


# ---------------------------------------------------------------------------
# Le dossier en paquets                                        (DOS-1 à DOS-6)
# ---------------------------------------------------------------------------

def test_chaque_paquet_a_des_chapitres_existants_et_un_resume():
    chapitres = set(dossier.chapitres())
    assert set(dossier.socle()) <= chapitres
    assert "10.1" not in dossier.socle()
    for code, paquet in dossier.paquets().items():
        assert paquet["chapitres"] and set(paquet["chapitres"]) <= chapitres, code
        texte = dossier.resume(code)
        assert texte and texte.startswith("# Résumé"), code
        assert "—" not in texte, code
        for mot in ("thomas", "lorette", "lusse"):
            assert mot not in texte.lower(), (code, mot)


def test_tous_les_chapitres_utiles_sont_dans_un_paquet_ou_le_socle():
    ranges = set(dossier.socle())
    for paquet in dossier.paquets().values():
        ranges |= set(paquet["chapitres"])
    # 10.5 (scénarios de test) et 11.3 (sources) ne servent pas au coach.
    assert set(dossier.chapitres()) - ranges == {"10.5", "11.3"}


def test_un_paquet_part_en_resume_ou_en_complet():
    resume = dossier.texte_des_paquets({"musculation": "resume"})
    complet = dossier.texte_des_paquets({"musculation": "complet"})
    assert "# Résumé : Musculation" in resume and "\n# 4.4 " not in resume
    assert "\n# 4.4 " in complet and "# Résumé" not in complet
    assert "musculation (résumé)" in resume and "musculation (complet)" in complet
    assert "Seul le socle est joint" in dossier.texte_des_paquets({})
    # Un chapitre du socle n'est jamais joint deux fois.
    sante = dossier.texte_des_paquets({"sante": "complet"})
    assert "\n# 2.4 " not in sante and "\n# 8.4 " in sante


def test_un_meme_choix_donne_le_meme_texte():
    choix = {"sante": "resume", "course": "complet"}
    assert dossier.texte_des_paquets(choix) == dossier.texte_des_paquets(dict(
        reversed(list(choix.items()))))


def test_les_mots_cles_trouvent_le_paquet():
    assert aiguillage.par_mots_cles("J'ai mal au genou depuis hier") == {"sante": "resume"}
    assert "course" in aiguillage.par_mots_cles("Quelle allure pour mon footing ?")
    assert "alimentation" in aiguillage.par_mots_cles("Combien de protéines par jour ?")
    assert aiguillage.par_mots_cles("Salut") == {}


def test_la_reponse_de_haiku_se_lit_sans_faire_confiance():
    assert aiguillage.lire_la_reponse("course:resume, sante:complet") == \
        {"course": "resume", "sante": "complet"}
    assert aiguillage.lire_la_reponse("Musculation : résumé") == {"musculation": "resume"}
    assert aiguillage.lire_la_reponse("aucun") == {}
    assert aiguillage.lire_la_reponse("pirate:complet, course:tout") == {}


def test_un_chapitre_conditionnel_ne_part_en_complet_que_s_il_sert():
    # DOS-7 : le trail et l'alimentation de course restent à lire, sauf besoin.
    route = dossier.texte_des_paquets({"course": "complet"})
    assert "# 5.3" not in route and "# 5.8" not in route and "# 5.6" in route
    assert "laissés de côté ici, à lire au besoin : 5.3, 5.8" in route
    trail = dossier.texte_des_paquets({"course": "complet", "_conditions": "trail"})
    assert "# 5.3" in trail and "# 5.8" not in trail


def test_le_moment_et_les_objectifs_choisissent_sans_haiku(u):
    choix = aiguillage.choisir(u, "plan")
    # L'objectif de u est « Prendre du muscle » (pilier physique).
    assert choix.choix == {"planification": "complet", "objectifs": "resume",
                           "sante": "resume", "musculation": "complet"}
    assert choix.par == ""
    assert aiguillage.choisir(u, "synthese").choix["musculation"] == "resume"


def test_haiku_choisit_pour_un_message_libre_et_le_plus_genereux_l_emporte(u, ecrit):
    joue = ecrit("course:complet, sante:resume")
    choix = aiguillage.choisir(u, "signalement", "Mon tibia tire quand je cours",
                               avant="Comment s'est passée ta sortie ?")
    assert choix.par == "haiku"
    # Le signalement joint la santé en complet : Haiku ne la rabaisse pas.
    assert choix.choix["sante"] == "complet" and choix.choix["course"] == "complet"
    assert "Comment s'est passée ta sortie ?" in joue.appels[0]["texte"]
    assert joue.appels[0]["modele"].startswith("claude-haiku")


def test_sans_haiku_les_mots_cles_prennent_le_relais(u):
    choix = aiguillage.choisir(u, "chat", "Je peux manger quoi avant la salle ?")
    assert choix.par == "mots"
    assert choix.choix == {"musculation": "resume", "alimentation": "resume"}


def test_l_appel_joint_les_paquets_choisis_et_le_note(u, faux):
    joue = faux(dit("Bois avant, pendant et après."))
    question(u, "Combien boire pendant un footing ?")

    systeme = joue.appels[0]["systeme"]
    assert len(systeme) == 3
    assert "# Résumé : Course" in systeme[1]["text"]
    assert "\n# 4.4 " not in systeme[1]["text"]
    assert un("SELECT paquets FROM appel_coach") == ["course:resume", "alimentation:resume"]
    deroule = un("SELECT deroule FROM appel_coach")
    assert deroule[0]["par"] == "mots"


# ---------------------------------------------------------------------------
# La mémoire en base                                           (MEM-2 à MEM-5)
# ---------------------------------------------------------------------------

def test_le_coach_n_ecrit_que_la_semaine_et_la_globale(u):
    assert un("SELECT ecrire_memoire(%s, 'semaine', 'Bonne semaine', 'coach')", u)
    assert refus("SELECT ecrire_memoire(%s, 'mois', 'x', 'coach')", u) == "non_autorise"
    assert refus("SELECT ecrire_memoire(%s, 'semaine', 'x', 'coach', %s)",
                 u, lundi_de(aujourd_hui()) - timedelta(days=7)) == "non_autorise"
    # L'utilisateur, lui, corrige n'importe quel étage.
    assert un("SELECT ecrire_memoire(%s, 'mois', 'corrigé', 'utilisateur')", u)


def test_chaque_etage_a_sa_limite(u):
    assert refus("SELECT ecrire_memoire(%s, 'semaine', repeat('a', 3001), 'coach')",
                 u) == "memoire_trop_longue"
    assert refus("SELECT ecrire_memoire(%s, 'globale', repeat('a', 4001), 'utilisateur')",
                 u) == "memoire_trop_longue"
    assert un("SELECT ecrire_memoire(%s, 'globale', repeat('a', 4000), 'utilisateur')", u)


def test_une_ecriture_ajoute_une_version_et_rien_ne_s_ecrase(u):
    premiere = un("SELECT ecrire_memoire(%s, 'globale', 'v1', 'coach')", u)
    assert un("SELECT ecrire_memoire(%s, 'globale', 'v1', 'coach')", u) == premiere
    seconde = un("SELECT ecrire_memoire(%s, 'globale', 'v2', 'coach')", u)
    assert seconde != premiere
    assert un("SELECT texte FROM v_memoire_coach WHERE id_utilisateur = %s "
              "AND niveau = 'globale'", u) == "v2"

    un("SELECT restaurer_memoire(%s, %s)", u, premiere)
    assert un("SELECT texte FROM v_memoire_coach WHERE id_utilisateur = %s "
              "AND niveau = 'globale'", u) == "v1"
    assert un("SELECT count(*) FROM memoire_coach WHERE id_utilisateur = %s", u) == 3
    assert refus("SELECT restaurer_memoire(%s, %s)", _id("lorette"), seconde) == \
        "introuvable"


def test_le_contexte_porte_les_quatre_etages(u):
    sql("SELECT ecrire_memoire(%s, 'globale', 'GLOBALE-ICI', 'utilisateur')", u)
    sql("SELECT ecrire_memoire(%s, 'mois', 'MOIS-ICI', 'utilisateur')", u)
    sql("SELECT ecrire_memoire(%s, 'semaine', 'SEMAINE-ICI', 'coach')", u)
    premier = aujourd_hui().replace(day=1)
    passe = memoire.mois_precedent(premier)
    sql("SELECT ecrire_memoire(%s, 'archive_mois', 'ARCHIVE-ICI', 'resume', %s)", u, passe)

    texte = appel.consigne(u)[2]["text"]

    positions = [texte.index(m) for m in ("# Ta mémoire", "GLOBALE-ICI", "ARCHIVE-ICI",
                                           "MOIS-ICI", "SEMAINE-ICI")]
    assert positions == sorted(positions)
    assert memoire.mois_en_clair(passe).capitalize() in texte


def test_le_coach_tient_sa_memoire_par_un_outil(u, faux):
    faux(demande(("ecrire_memoire", {"niveau": "semaine",
                                     "texte": "Genou droit sensible mardi."})),
         dit("C'est noté."))
    question(u, "Retiens que mon genou droit était sensible mardi")
    assert memoire.etat(u)["semaine"]["texte"] == "Genou droit sensible mardi."
    assert memoire.etat(u)["semaine"]["auteur"] == "coach"


def test_le_carnet_devient_la_memoire_globale():
    lorette = _id("lorette")
    sql("INSERT INTO note_coach (id_utilisateur, categorie, texte, source, confirmee) "
        "VALUES (%s, 'preference', 'Aime courir le matin', 'utilisateur', true), "
        "(%s, 'efficacite', 'Récupère mal après 22 h', 'deduction', false)",
        lorette, lorette)
    sql((RACINE / "sql" / "056_memoire_du_coach.sql").read_text(encoding="utf-8"))
    sql((RACINE / "sql" / "056_memoire_du_coach.sql").read_text(encoding="utf-8"))

    globales = sql("SELECT texte, auteur FROM memoire_coach WHERE id_utilisateur = %s",
                   lorette)
    assert len(globales) == 1 and globales[0]["auteur"] == "reprise"
    assert "- Aime courir le matin" in globales[0]["texte"]
    assert "- Récupère mal après 22 h (à confirmer)" in globales[0]["texte"]


# ---------------------------------------------------------------------------
# L'importance des échanges                                             (MEM-8)
# ---------------------------------------------------------------------------

def test_une_question_simple_est_courante(u, faux):
    faux(dit("Oui."))
    question(u, "Je peux boire un café avant ?")
    assert [e["importance"] for e in sql("SELECT importance FROM echange ORDER BY "
                                         "id_echange")] == [1, 1]


def test_des_seances_proposees_comptent_plus_qu_un_bilan(u, plan, faux):
    faux(demande(("proposer_seance", SEANCE_DU_COACH | {"jour": jour(3).isoformat()})),
         dit("Séance posée."))
    appel.appeler_coach(appel.Demande(u, "synthese"))
    assert un("SELECT importance FROM echange WHERE auteur = 'coach'") == 2


def test_le_coach_marque_important_et_le_message_de_l_utilisateur_suit(u, faux):
    faux(demande(("marquer_important", {"raison": "Il arrête la course à pied"})),
         dit("Compris, on arrête la course."))
    question(u, "J'arrête la course à pied, je ne fais plus que de la salle")
    assert [(e["auteur"], e["importance"]) for e in sql(
        "SELECT auteur, importance FROM echange ORDER BY id_echange")] == \
        [("utilisateur", 3), ("coach", 3)]
    # La trace « important » ne fabrique aucun bouton.
    assert un("SELECT elements FROM echange WHERE auteur = 'coach'") == []


def test_lire_echanges_cherche_dans_tout_l_historique(u):
    for texte, importance in (("Douleur au genou en descente", 3),
                              ("Bonne séance", 1), ("Le genou va mieux", 2)):
        sql("INSERT INTO echange (id_utilisateur, auteur, moment, contenu, importance) "
            "VALUES (%s, 'utilisateur', 'chat', %s, %s)", u, texte, importance)
    # Les derniers échanges, déjà sous ses yeux, ne lui sont pas rendus une deuxième fois.
    for rang in range(configuration().coach_echanges_rendus - 1):
        sql("INSERT INTO echange (id_utilisateur, auteur, moment, contenu) "
            "VALUES (%s, 'systeme', 'chat', %s)", u, f"Réponse {rang}")
    sql("INSERT INTO echange (id_utilisateur, auteur, moment, contenu) "
        "VALUES (%s, 'utilisateur', 'chat', 'Mon genou, encore')", u)

    trouves = outils.lire_echanges(u, {"cherche": "genou"})["echanges"]
    assert [e["contenu"] for e in trouves] == ["Douleur au genou en descente",
                                              "Le genou va mieux"]
    importants = outils.lire_echanges(u, {"importance_min": 3})["echanges"]
    assert [e["contenu"] for e in importants] == ["Douleur au genou en descente"]
    assert outils.lire_echanges(_id("lorette"), {"cherche": "genou"})["echanges"] == []


# ---------------------------------------------------------------------------
# Le roulement de la nuit                                         (MEM-6, MEM-7)
# ---------------------------------------------------------------------------

def _echange(u: int, quand: date, contenu: str, importance: int = 1) -> None:
    sql("INSERT INTO echange (id_utilisateur, auteur, moment, contenu, importance, quand) "
        "VALUES (%s, 'utilisateur', 'chat', %s, %s, %s::DATE + TIME '12:00')",
        u, contenu, importance, quand)


def test_une_semaine_finie_est_versee_dans_le_mois_une_seule_fois(u, ecrit):
    lundi_passe = lundi_de(aujourd_hui()) - timedelta(days=7)
    sql("INSERT INTO memoire_coach (id_utilisateur, niveau, periode, texte, auteur) "
        "VALUES (%s, 'semaine', %s, 'Semaine dure, 3 séances sur 4.', 'coach')",
        u, lundi_passe)
    _echange(u, lundi_passe + timedelta(days=1), "Nouvel objectif : 10 km en 50 min", 3)
    _echange(u, lundi_passe + timedelta(days=2), "Bilan banal", 1)
    joue = ecrit("Mois : semaine dure, objectif 10 km posé.")

    fait = memoire.rouler(u)

    assert any("versée" in f for f in fait)
    resume = joue.appels[0]["texte"]
    assert "Semaine dure, 3 séances sur 4." in resume
    assert "Nouvel objectif : 10 km en 50 min" in resume
    assert "Bilan banal" not in resume and "1 échange(s) courant(s)" in resume
    assert "Ce qu'on garde toujours" in joue.appels[0]["systeme"]
    mois = sql("SELECT texte, couvre_jusqu_au, auteur, tokens_entree FROM memoire_coach "
               "WHERE id_utilisateur = %s AND niveau = 'mois' "
               "AND couvre_jusqu_au IS NOT NULL", u)
    assert mois[0]["couvre_jusqu_au"] == lundi_passe and mois[0]["auteur"] == "resume"
    assert mois[0]["tokens_entree"] == 500

    # Rejoué : rien n'est versé deux fois, aucun appel au modèle.
    ecrit()
    assert not any("versée" in f for f in memoire.rouler(u))


def test_un_mois_fini_est_archive_puis_verse_dans_la_globale(u, ecrit):
    premier = aujourd_hui().replace(day=1)
    for n in range(1, 5):
        sql("INSERT INTO memoire_coach (id_utilisateur, niveau, periode, texte, auteur) "
            "VALUES (%s, 'mois', %s, %s, 'resume')",
            u, memoire.mois_precedent(premier, n), f"Mois -{n} : court.")
    joue = ecrit("Globale : a commencé il y a quatre mois.")

    fait = memoire.rouler(u)

    # Quatre mois finis : archivés tels quels (assez courts), puis le plus vieux
    # sort des trois derniers et rejoint la globale. Un seul appel au modèle.
    assert sum("archivé" in f for f in fait) == 4
    assert len(joue.appels) == 1 and "Mois -4 : court." in joue.appels[0]["texte"]
    globale = memoire.en_vigueur(u, "globale")
    assert globale["texte"] == "Globale : a commencé il y a quatre mois."
    assert globale["couvre_jusqu_au"] == memoire.mois_precedent(premier, 4)
    assert [a["texte"] for a in memoire.etat(u)["trois_mois"]] == \
        ["Mois -3 : court.", "Mois -2 : court.", "Mois -1 : court."]

    ecrit()
    assert memoire.rouler(u) == []


def test_un_resume_trop_long_est_relance_puis_abandonne_sans_rien_casser(u, ecrit):
    premier = aujourd_hui().replace(day=1)
    sql("INSERT INTO memoire_coach (id_utilisateur, niveau, periode, texte, auteur) "
        "VALUES (%s, 'mois', %s, repeat('détail ', 400), 'resume')",
        u, memoire.mois_precedent(premier))
    joue = ecrit("x" * 1600, "y" * 1600)

    fait = memoire.rouler(u)

    assert len(joue.appels) == 2 and "trop longue" in joue.appels[1]["texte"]
    assert fait and fait[-1].startswith("interrompu")
    assert un("SELECT count(*) FROM memoire_coach WHERE niveau = 'archive_mois'") == 0

    # La nuit suivante réessaie, et réussit.
    ecrit("Un mois chargé.")
    assert any("archivé" in f for f in memoire.rouler(u))


def test_minuit_fait_le_roulement(u, ecrit):
    from api.coach import planifie
    ecrit()
    assert planifie.minuit()["memoire"] == {"thomas": []}


# ---------------------------------------------------------------------------
# Telegram et routes                                                    (MEM-5)
# ---------------------------------------------------------------------------

def test_le_gras_du_coach_est_rendu_et_le_reste_echappe():
    assert coach_tg.mise_en_forme("a < b et **à retenir** <script>") == \
        "a &lt; b et <b>à retenir</b> &lt;script&gt;"
    assert coach_tg.mise_en_forme("2 ** 3") == "2 ** 3"


def test_memoire_dans_le_bot(u):
    sql("SELECT ecrire_memoire(%s, 'semaine', 'Première version', 'coach')", u)

    ecran = coach_tg.commande("memoire", u, [])
    assert "Ce que le coach retient" in ecran.texte and "Première version" in ecran.texte

    ecran = coach_tg.commande("memoire", u, ["semaine", "Version", "corrigée"])
    assert "Mémoire corrigée" in ecran.texte
    assert memoire.etat(u)["semaine"]["texte"] == "Version corrigée"
    assert memoire.etat(u)["semaine"]["auteur"] == "utilisateur"

    ecran = coach_tg.repondre(u, "memr", "s")
    assert "Version précédente remise" in ecran.texte
    assert memoire.etat(u)["semaine"]["texte"] == "Première version"
    assert "Première version" in coach_tg.repondre(u, "mem", "s").texte


def test_routes_de_la_memoire(u):
    rendu = routes.corriger_memoire(qui(u), "globale",
                                    routes.TexteMemoire(texte="Préfère le matin."))
    assert rendu["memoire"]["globale"]["texte"] == "Préfère le matin."
    assert "Préfère le matin." in routes.exporter_memoire(qui(u))
    versions = routes.versions_memoire(qui(u), "globale")
    assert len(versions) == 1 and versions[0]["auteur"] == "utilisateur"


def test_le_reglage_des_paquets_est_du_json_valide():
    reglage = json.loads((RACINE / "coach" / "paquets.json").read_text(encoding="utf-8"))
    for moment, choix in reglage["moments"].items():
        assert moment in outils.MOMENTS
        assert set(choix) <= set(dossier.paquets()) and set(choix.values()) <= {
            "resume", "complet"}


def test_le_cout_de_chaque_appel_est_compte(u, faux):
    tour = dit("Oui.")
    tour.tokens_cache_ecrit = 150
    faux(tour)
    question(u, "Je peux courir demain ?")
    appel_fait = sql("SELECT tokens_cache_ecrit, deroule, modele, tokens_entree, tokens_cache, "
                     "tokens_sortie FROM appel_coach")[0]
    assert appel_fait["tokens_cache_ecrit"] == 150
    assert [d for d in appel_fait["deroule"] if "jetons" in d] == [
        {"jetons": 0, "neufs": 50, "cache_ecrit": 150, "cache_lu": 800, "sortie": 50,
         "arret": "end_turn"}]
    # 50 neufs à 2 $, 150 écrits à 2,5 $, 800 lus à 0,10 $, 50 sortis à 10 $ le million.
    assert float(un("SELECT cout_appel_usd(%s, 1000, 800, 150, 50)", "claude-sonnet-5-5")) \
        == round((50 * 2 + 150 * 2.5 + 800 * 0.1 + 50 * 10) / 1e6, 4)
    assert un("SELECT cout_usd FROM v_cout_coach") is not None


def test_le_texte_envoye_au_modele_s_ecrit_dans_un_fichier(u, faux, monkeypatch, tmp_path):
    from api.config import configuration
    monkeypatch.setattr(configuration(), "coach_trace_dossier", str(tmp_path))
    faux(demande(("lire_semaine", {})), dit("Ta semaine est calme."))
    question(u, "Comment est ma semaine ?")

    fichiers = list(tmp_path.glob("appel_*.md"))
    assert len(fichiers) == 1
    texte = fichiers[0].read_text(encoding="utf-8")
    for attendu in ("## Consigne 1 : Consigne, sommaire et socle du dossier",
                    "# Ton cadre de travail", "## Consigne 3 : Contexte de l'utilisateur",
                    "# Moment : chat", "Comment est ma semaine ?",
                    "**Outil demandé : `lire_semaine`**", "**Résultat**",
                    "## Sa réponse finale", "Ta semaine est calme."):
        assert attendu in texte, attendu


def test_sans_dossier_aucune_trace(u, faux, tmp_path):
    faux(dit("Oui."))
    question(u)
    assert not list(tmp_path.glob("*"))


def test_ajouter_memoire_garde_le_texte_et_ajoute_une_ligne(u):
    # MEM-9 : la mémoire de la semaine s'allonge d'une ligne, sans être réécrite.
    outils.ecrire_memoire(u, {"niveau": "semaine", "texte": "Lundi : footing fait."})
    outils.ajouter_memoire(u, {"ligne": "Préfère courir le matin."})
    texte = memoire.en_vigueur(u, "semaine", lundi_de(aujourd_hui()))["texte"]
    assert texte == "Lundi : footing fait.\n- Préfère courir le matin."


def test_le_chat_enregistre_une_mesure_donnee_dans_un_message(u):
    # MES-7 : « je pèse 70 kg » s'enregistre, au lieu d'être seulement « noté ».
    assert "noter_mesure" in {o.nom for o in outils.outils_du_moment("chat")}
    outils.noter_mesure(u, {"type": "poids", "valeur": 70, "unite": "kg"})
    assert outils.lire_mesures(u, {"type": "poids"})["mesures"][0]["valeur"] == 70
