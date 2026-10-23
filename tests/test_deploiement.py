"""Le déploiement, joué pour de bon avec un vrai dépôt git.

`outils/deployer.sh` tourne toutes les deux minutes sur le serveur. Il comparait
HEAD à origin/main, et fusionnait avant d'appliquer les migrations : si l'une
d'elles échouait, la fusion était déjà faite, et le passage suivant concluait
qu'il n'y avait plus rien à faire. Le serveur restait sur l'ancienne API avec
une base à moitié migrée, et la seule trace était une ligne dans journalctl.

Ce qu'on vérifie ici : qu'un échec se voit, se dit une fois sur Telegram, et se
réessaie ; et qu'un déploiement n'est compté réussi que si l'API répond.

Rien de réel n'est touché. Le dépôt est fabriqué dans un dossier temporaire, et
`docker` comme `curl` sont remplacés par des faux qui notent ce qu'on leur
demande.
"""

import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from tests.conftest import RACINE

SCRIPT = RACINE / "outils" / "deployer.sh"

pytestmark = pytest.mark.skipif(
    shutil.which("git") is None or not SCRIPT.exists(),
    reason="demande git, et le script de déploiement")

FAUX_DOCKER = """#!/bin/sh
echo "docker $*" >> "$SCENE/appels"
# Ce qui arrive sur l'entrée de psql : c'est là que passe la note au journal.
case "$*" in *"--set libelle="*) cat >> "$SCENE/journal" ;; esac
case "$*" in
  *"pg_dump"*) [ -f "$SCENE/sauvegarde_cassee" ] && { echo "pg_dump: connexion refusée" >&2; exit 1; }
               echo "PGDMP copie" ;;
  *"SELECT id_telegram"*) echo 4242 ;;
  "compose up"*) [ -f "$SCENE/image_cassee" ] && { echo "build failed"; exit 1; } ;;
  "compose logs"*) echo "api  | Traceback: fonction SQL introuvable" ;;
esac
exit 0
"""

FAUX_CURL = """#!/bin/sh
case "$*" in
  *api.telegram.org*)
    echo "--- message" >> "$SCENE/telegram"
    for mot in "$@"; do
      case "$mot" in text=*) echo "${mot#text=}" >> "$SCENE/telegram" ;; esac
    done ;;
  *"/sante"*)
    echo "sonde $*" >> "$SCENE/sondes"
    [ -f "$SCENE/api_morte" ] && exit 22
    echo '{"etat":"ok","base":"ok"}' ;;
esac
exit 0
"""

# Le script de migrations du dépôt factice : il obéit à un drapeau, pour qu'un
# test puisse le faire échouer sans toucher à la moindre base.
FAUSSES_MIGRATIONS = """#!/bin/sh
echo "migrations" >> "$SCENE/appels"
if [ -f "$SCENE/migration_cassee" ]; then
  echo "psql:047.sql:12: ERROR:  division by zero"
  exit 3
fi
echo "0 migration(s) appliquée(s)."
"""


def _git(dossier: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.org",
         "-c", "init.defaultBranch=main", *arguments],
        cwd=dossier, capture_output=True, text=True, check=True).stdout.strip()


class Scene:
    """Un dépôt « GitHub », sa copie sur le « serveur », et ce qui s'y passe."""

    def __init__(self, racine: Path):
        self.racine = racine
        self.origine = racine / "origine.git"
        self.auteur = racine / "auteur"      # là où l'on écrit et pousse
        self.serveur = racine / "serveur"    # là où le script déploie
        self.etat = racine / "etat"
        self.faux = racine / "faux"
        self.reglages: dict[str, str] = {}

        self.origine.mkdir()
        _git(self.origine, "init", "--bare", "--initial-branch=main")
        _git(racine, "clone", str(self.origine), "auteur")

        (self.auteur / "sql").mkdir()
        (self.auteur / "outils").mkdir()
        migrations = self.auteur / "sql" / "appliquer.sh"
        migrations.write_text(FAUSSES_MIGRATIONS)
        migrations.chmod(0o755)
        shutil.copy(SCRIPT, self.auteur / "outils" / "deployer.sh")
        self.pousser("premier commit")

        _git(racine, "clone", str(self.origine), "serveur")
        (self.serveur / ".env").write_text(
            "TELEGRAM_TOKEN=123:abc\nPOSTGRES_USER=planif\nPOSTGRES_DB=planif\n")

        self.faux.mkdir()
        for nom, contenu in (("docker", FAUX_DOCKER), ("curl", FAUX_CURL)):
            (self.faux / nom).write_text(contenu)
            (self.faux / nom).chmod(0o755)

    def pousser(self, message: str) -> str:
        (self.auteur / "version.txt").write_text(f"{message}\n")
        _git(self.auteur, "add", "-A")
        _git(self.auteur, "commit", "-m", message)
        _git(self.auteur, "push", "origin", "HEAD:main")
        return _git(self.auteur, "rev-parse", "HEAD")

    def passage(self) -> subprocess.CompletedProcess:
        environnement = {
            **os.environ,
            "DEPOT": str(self.serveur), "PLANIF_ETAT": str(self.etat),
            "SCENE": str(self.racine),
            "PATH": f"{self.faux}:{os.environ['PATH']}",
            # Les tests n'attendent pas l'API une minute et demie.
            "PLANIF_ESSAIS_SANTE": "2", "PLANIF_PAUSE_SANTE": "0",
            **self.reglages,
        }
        return subprocess.run(["sh", str(self.serveur / "outils" / "deployer.sh")],
                              capture_output=True, text=True, env=environnement,
                              timeout=60)

    def drapeau(self, nom: str, leve: bool = True) -> None:
        fichier = self.racine / nom
        fichier.write_text("") if leve else fichier.unlink(missing_ok=True)

    def lire(self, nom: str) -> str:
        fichier = self.racine / nom
        return fichier.read_text() if fichier.exists() else ""

    def messages(self) -> list[str]:
        return [m.strip() for m in self.lire("telegram").split("--- message") if m.strip()]

    def deploye(self) -> str:
        temoin = self.etat / "deploye"
        return temoin.read_text().strip() if temoin.exists() else ""

    def sauvegardes(self) -> list[Path]:
        return sorted((self.etat / "sauvegardes").glob("*"))

    def vieillir_l_echec(self) -> None:
        """Fait comme si le dernier essai datait d'une heure."""
        il_y_a_une_heure = time.time() - 3600
        os.utime(self.etat / "echec", (il_y_a_une_heure, il_y_a_une_heure))


@pytest.fixture
def scene(tmp_path) -> Scene:
    return Scene(tmp_path)


# ---------------------------------------------------------------------------
# Quand tout va bien
# ---------------------------------------------------------------------------

def test_le_premier_passage_deploie_et_retient_le_commit(scene):
    passage = scene.passage()

    assert passage.returncode == 0, passage.stdout + passage.stderr
    assert "Déployé." in passage.stdout
    assert scene.deploye() == _git(scene.auteur, "rev-parse", "HEAD")
    # Dans l'ordre : les migrations, puis l'API.
    appels = scene.lire("appels")
    assert appels.index("migrations") < appels.index("docker compose up")


def test_rien_a_faire_ne_dit_rien(scene):
    scene.passage()

    second = scene.passage()

    # Un journal rempli de « rien à faire » toutes les deux minutes noierait la
    # ligne qui compte le jour où un déploiement échoue.
    assert second.returncode == 0
    assert second.stdout == ""


def test_un_nouveau_commit_se_deploie(scene):
    scene.passage()
    nouveau = scene.pousser("une correction")

    passage = scene.passage()

    assert passage.returncode == 0
    assert scene.deploye() == nouveau
    assert scene.messages() == [], "un déploiement réussi ne dérange personne"


# ---------------------------------------------------------------------------
# Quand ça casse
# ---------------------------------------------------------------------------

def test_une_migration_ratee_se_dit_et_ne_passe_pas_pour_reussie(scene):
    scene.passage()
    avant = scene.deploye()
    scene.pousser("une migration fautive")
    scene.drapeau("migration_cassee")
    (scene.racine / "appels").unlink()

    passage = scene.passage()

    assert passage.returncode != 0
    # Le témoin n'a pas bougé : le serveur sait qu'il n'est pas à jour.
    assert scene.deploye() == avant
    # L'API n'a pas été reconstruite sur une base à moitié migrée.
    assert "docker compose up" not in scene.lire("appels")
    # Et quelqu'un est prévenu, avec de quoi comprendre.
    messages = scene.messages()
    assert len(messages) == 1
    assert "Déploiement raté" in messages[0]
    assert "une migration fautive" in messages[0]
    assert "division by zero" in messages[0]


def test_le_serveur_ne_se_croit_pas_a_jour_apres_un_echec(scene):
    """Le défaut d'origine.

    Après l'échec, la fusion est faite : HEAD vaut origin/main. L'ancien script
    en concluait qu'il n'y avait plus rien à faire, pour toujours.
    """
    scene.passage()
    fautif = scene.pousser("une migration fautive")
    scene.drapeau("migration_cassee")
    scene.passage()
    assert _git(scene.serveur, "rev-parse", "HEAD") == fautif

    # La cause disparaît, sans nouveau commit : une base qui redémarrait, un
    # réseau coupé pendant la construction de l'image.
    scene.drapeau("migration_cassee", leve=False)
    scene.vieillir_l_echec()
    passage = scene.passage()

    assert passage.returncode == 0
    assert scene.deploye() == fautif
    assert "Déploiement rétabli" in scene.messages()[-1]


def test_un_echec_ne_previent_qu_une_fois(scene):
    scene.passage()
    scene.pousser("une migration fautive")
    scene.drapeau("migration_cassee")

    scene.passage()
    scene.vieillir_l_echec()
    scene.passage()
    scene.vieillir_l_echec()
    scene.passage()

    # Trois essais, un seul message : un déploiement cassé un vendredi soir ne
    # doit pas faire vibrer le téléphone tout le week-end.
    assert len(scene.messages()) == 1


def test_un_echec_recent_n_est_pas_reessaye_tout_de_suite(scene):
    scene.passage()
    scene.pousser("une migration fautive")
    scene.drapeau("migration_cassee")
    scene.passage()
    (scene.racine / "appels").unlink()

    encore = scene.passage()

    # Deux minutes plus tard : on attend, sans rien relancer ni rien écrire.
    assert encore.stdout == ""
    assert scene.lire("appels") == ""


def test_le_correctif_part_sans_attendre(scene):
    scene.passage()
    scene.pousser("une migration fautive")
    scene.drapeau("migration_cassee")
    scene.passage()

    scene.drapeau("migration_cassee", leve=False)
    correctif = scene.pousser("le correctif")
    passage = scene.passage()

    assert passage.returncode == 0
    assert scene.deploye() == correctif
    assert "Déploiement rétabli" in scene.messages()[-1]


def test_une_api_qui_ne_redemarre_pas_est_un_echec(scene):
    scene.passage()
    avant = scene.deploye()
    scene.pousser("une API qui tombe au démarrage")
    scene.drapeau("api_morte")

    passage = scene.passage()

    # `docker compose up` a réussi, mais l'API ne répond pas : ce n'est pas un
    # déploiement, et l'ancien script l'aurait annoncé « Déployé ».
    assert passage.returncode != 0
    assert scene.deploye() == avant
    assert "Déploiement raté" in scene.messages()[-1]
    assert "/sante" in scene.messages()[-1]


def test_une_image_qui_ne_se_construit_pas_est_un_echec(scene):
    scene.passage()
    avant = scene.deploye()
    scene.pousser("une dépendance introuvable")
    scene.drapeau("image_cassee")

    passage = scene.passage()

    assert passage.returncode != 0
    assert scene.deploye() == avant
    assert len(scene.messages()) == 1


def test_la_sonde_frappe_a_l_adresse_ou_l_api_ecoute(scene):
    # API_BIND restreint l'écoute à une adresse. Sonder la boucle locale quand
    # l'API écoute ailleurs ferait passer chaque déploiement pour un échec.
    with (scene.serveur / ".env").open("a") as env:
        env.write("API_BIND=100.64.0.7\nAPI_PORT=8123\n")

    passage = scene.passage()

    assert passage.returncode == 0
    assert "http://100.64.0.7:8123/sante" in scene.lire("sondes")


def test_la_sonde_vise_la_boucle_locale_par_defaut(scene):
    scene.passage()

    assert "http://127.0.0.1:8000/sante" in scene.lire("sondes")


def test_un_premier_deploiement_rate_se_dit_aussi(scene):
    # Le destinataire n'est retenu qu'après un succès. Sans le demander à la
    # base au moment de l'alerte, le tout premier échec resterait muet : c'est
    # justement le passage où le nouveau script s'installe.
    scene.drapeau("migration_cassee")

    passage = scene.passage()

    assert passage.returncode != 0
    assert len(scene.messages()) == 1
    assert "Déploiement raté" in scene.messages()[0]


def test_un_deploiement_s_inscrit_au_journal(scene):
    scene.pousser("l'apostrophe ne casse rien")
    (scene.racine / "appels").unlink(missing_ok=True)

    scene.passage()

    # Le sujet du commit voyage en variable psql, pas dans la requête : une
    # apostrophe dans un message de commit ne doit pas faire une erreur SQL.
    appels = scene.lire("appels")
    assert "--set libelle=Déploiement de " in appels
    assert "--set detail=l'apostrophe ne casse rien" in appels
    requete = scene.lire("journal")
    assert "noter_evenement('deploiement', :'libelle', :'detail', TRUE)" in requete
    assert "apostrophe" not in requete


def test_un_deploiement_rate_s_inscrit_une_fois(scene):
    scene.passage()
    scene.pousser("une migration fautive")
    scene.drapeau("migration_cassee")
    (scene.racine / "appels").unlink()

    scene.passage()
    scene.vieillir_l_echec()
    scene.passage()

    assert scene.lire("appels").count("--set libelle=Déploiement raté de ") == 1


# ---------------------------------------------------------------------------
# La copie de la base
# ---------------------------------------------------------------------------

def test_la_base_est_copiee_avant_les_migrations(scene):
    commit = scene.pousser("une migration")

    passage = scene.passage()

    assert passage.returncode == 0, passage.stdout + passage.stderr
    appels = scene.lire("appels")
    assert appels.index("pg_dump") < appels.index("migrations")
    assert "--format=custom" in appels
    copies = scene.sauvegardes()
    assert [c.name.endswith(f"-{commit[:7]}.dump") for c in copies] == [True]
    assert copies[0].read_text() == "PGDMP copie\n"
    # Des données personnelles : lisibles du seul compte du serveur.
    assert copies[0].stat().st_mode & 0o077 == 0
    assert (scene.etat / "sauvegardes").stat().st_mode & 0o077 == 0


def test_sans_copie_rien_n_est_migre(scene):
    scene.passage()
    avant = scene.deploye()
    scene.pousser("une migration")
    scene.drapeau("sauvegarde_cassee")
    (scene.racine / "appels").unlink()

    passage = scene.passage()

    assert passage.returncode != 0
    assert scene.deploye() == avant
    appels = scene.lire("appels")
    assert "migrations" not in appels
    assert "docker compose up" not in appels
    # Aucune copie à moitié écrite ne reste, et l'ancienne est toujours là.
    assert len(scene.sauvegardes()) == 1
    assert "Sauvegarde de la base impossible" in scene.messages()[-1]


def test_seules_les_dernieres_copies_restent(scene):
    scene.reglages["PLANIF_SAUVEGARDES_GARDEES"] = "2"
    scene.passage()
    scene.pousser("deux")
    scene.passage()
    dernier = scene.pousser("trois")

    scene.passage()

    copies = scene.sauvegardes()
    assert len(copies) == 2
    assert any(c.name.endswith(f"-{dernier[:7]}.dump") for c in copies)
