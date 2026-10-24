"""La copie de la base hors du serveur : sur le Mac, et chiffrée dans iCloud.

`outils/copier_hors_serveur.sh` tourne sur le Mac. Ici, `ssh`, `age` et
`pg_restore` sont des faux qui notent ce qu'on leur demande : rien ne part vers
un serveur, et iCloud est un dossier temporaire. La surveillance du serveur,
elle, se teste sur la base des tests.
"""

import os
import shutil
import subprocess
import time
from datetime import timedelta
from pathlib import Path

import pytest

from api import administration
from tests.conftest import RACINE
from tests.test_ensemble import sql, un

SCRIPT = RACINE / "outils" / "copier_hors_serveur.sh"

FAUX_SSH = """#!/bin/sh
# Les options, puis la machine, puis la commande.
while [ "$#" -gt 1 ]; do
  case "$1" in -o) shift 2 ;; *) break ;; esac
done
serveur="$1"; shift
echo "ssh $serveur $*" >> "$SCENE/appels"
[ -f "$SCENE/serveur_injoignable" ] && exit 255
case "$*" in
  *pg_dump*) echo "PGDMP copie de la base" ;;
  *psql*) cat >> "$SCENE/journal" ;;
esac
"""

FAUX_AGE = """#!/bin/sh
# age --recipient CLE --output SORTIE ENTREE : « chiffre » en recopiant.
echo "age $*" >> "$SCENE/appels"
sortie="$4"; entree="$5"
{ echo "age-encryption.org/v1 pour $2"; cat "$entree"; } > "$sortie"
"""

FAUX_PG_RESTORE = """#!/bin/sh
echo "pg_restore $*" >> "$SCENE/appels"
[ -f "$SCENE/copie_illisible" ] && { echo "archive illisible" >&2; exit 1; }
exit 0
"""


class Scene:
    def __init__(self, racine: Path):
        self.racine = racine
        self.copies = racine / "Sauvegardes" / "planif"
        self.icloud = racine / "iCloud" / "Sauvegardes planif"
        faux = racine / "faux"
        faux.mkdir()
        for nom, contenu in (("ssh", FAUX_SSH), ("age", FAUX_AGE),
                             ("pg_restore", FAUX_PG_RESTORE)):
            (faux / nom).write_text(contenu)
            (faux / nom).chmod(0o755)
        self.reglages = racine / "sauvegardes.env"
        self.reglages.write_text("PLANIF_SERVEUR=thomas@serveur\n"
                                 "PLANIF_AGE_DESTINATAIRE=age1cledetest\n")
        self.environnement = {
            "PATH": f"{faux}:/usr/bin:/bin", "HOME": str(racine), "SCENE": str(racine),
            "PLANIF_REGLAGES": str(self.reglages),
            "PLANIF_COPIES": str(self.copies), "PLANIF_ICLOUD": str(self.icloud),
        }

    def passage(self, **reglages) -> subprocess.CompletedProcess:
        return subprocess.run(["sh", str(SCRIPT)], capture_output=True, text=True,
                              env={**self.environnement, **reglages}, timeout=30)

    def drapeau(self, nom: str) -> None:
        (self.racine / nom).write_text("")

    def lire(self, nom: str) -> str:
        fichier = self.racine / nom
        return fichier.read_text() if fichier.exists() else ""

    def sur_le_mac(self) -> list[Path]:
        return sorted(self.copies.glob("*")) if self.copies.exists() else []

    def dans_icloud(self) -> list[Path]:
        return sorted(self.icloud.glob("*")) if self.icloud.exists() else []


@pytest.fixture
def scene(tmp_path) -> Scene:
    if shutil.which("sh") is None:
        pytest.skip("demande sh")
    return Scene(tmp_path)


def test_une_copie_arrive_sur_le_mac_et_chiffree_dans_icloud(scene):
    passage = scene.passage()

    assert passage.returncode == 0, passage.stdout + passage.stderr
    [copie] = scene.sur_le_mac()
    assert copie.read_text() == "PGDMP copie de la base\n"
    [chiffree] = scene.dans_icloud()
    assert chiffree.name == copie.name + ".age"
    assert chiffree.read_text().startswith("age-encryption.org/v1 pour age1cledetest")
    # Données de santé : lisibles du seul compte du Mac.
    assert copie.stat().st_mode & 0o077 == 0
    assert chiffree.stat().st_mode & 0o077 == 0

    appels = scene.lire("appels")
    assert "pg_dump --username=planif --dbname=planif --format=custom" in appels
    # Vérifiée avant d'être gardée.
    assert appels.index("pg_restore --list") < appels.index("age --recipient")
    # Et inscrite au journal du serveur, que lit la surveillance.
    assert "noter_evenement('sauvegarde_externe', :'libelle', NULL, TRUE)" in \
        scene.lire("journal")


def test_un_serveur_injoignable_ne_laisse_rien(scene):
    scene.drapeau("serveur_injoignable")

    passage = scene.passage()

    assert passage.returncode != 0
    assert "Le serveur n'a pas rendu de copie" in passage.stdout
    assert scene.sur_le_mac() == [] and scene.dans_icloud() == []


def test_une_copie_illisible_n_est_pas_gardee(scene):
    scene.drapeau("copie_illisible")

    passage = scene.passage()

    assert passage.returncode != 0
    assert scene.sur_le_mac() == [] and scene.dans_icloud() == []
    assert scene.lire("journal") == "", "une copie ratée ne se note pas comme faite"


def test_seules_les_dernieres_copies_restent(scene):
    scene.copies.mkdir(parents=True)
    scene.icloud.mkdir(parents=True)
    for rang in range(3):
        ancienne = time.time() - 86400 * (rang + 1)
        for fichier in (scene.copies / f"planif-2026010{rang}-120000.dump",
                        scene.icloud / f"planif-2026010{rang}-120000.dump.age"):
            fichier.write_text("ancienne")
            os.utime(fichier, (ancienne, ancienne))

    passage = scene.passage(PLANIF_COPIES_GARDEES="2", PLANIF_ICLOUD_GARDEES="1")

    assert passage.returncode == 0, passage.stdout + passage.stderr
    assert [f.name for f in scene.sur_le_mac()][0] == "planif-20260100-120000.dump"
    assert len(scene.sur_le_mac()) == 2
    # La seule copie gardée dans iCloud est celle du jour.
    [chiffree] = scene.dans_icloud()
    assert "ancienne" not in chiffree.read_text()


def test_sans_reglages_rien_ne_part(scene):
    scene.reglages.write_text("")

    passage = scene.passage()

    assert passage.returncode != 0
    assert "PLANIF_SERVEUR manque" in passage.stdout
    assert scene.lire("appels") == ""


# ---------------------------------------------------------------------------
# Côté serveur : la surveillance (ADM-2)
# ---------------------------------------------------------------------------

@pytest.fixture
def sans_copie(base):
    def vider():
        sql("DELETE FROM evenement WHERE objet = 'sauvegarde_externe'")
        sql("DELETE FROM alerte_admin")
        sql("DELETE FROM notification WHERE type = 'administration'")
    vider()
    yield
    vider()


def _copie_il_y_a(duree: timedelta) -> None:
    sql("SELECT noter_evenement('sauvegarde_externe', 'Copie hors serveur, 2,1M', NULL, TRUE)")
    sql("UPDATE evenement SET quand = now() - %s WHERE objet = 'sauvegarde_externe'", duree)


def _alertes() -> list[str]:
    return [ligne["contenu"] for ligne in
            sql("SELECT contenu FROM notification WHERE type = 'administration'")]


def test_sans_copie_installee_rien_n_est_dit(sans_copie):
    administration._copie_externe()

    assert _alertes() == []
    assert "Copie hors du serveur : <b>pas installée</b>" in administration.etat()


def test_trois_jours_sans_copie_previennent(sans_copie):
    _copie_il_y_a(timedelta(days=4))

    administration._copie_externe()

    assert any("Aucune copie de la base hors du serveur" in t for t in _alertes())


def test_une_copie_recente_ne_dit_rien_puis_leve_l_alerte(sans_copie):
    _copie_il_y_a(timedelta(days=4))
    administration._copie_externe()
    sql("DELETE FROM evenement WHERE objet = 'sauvegarde_externe'")

    _copie_il_y_a(timedelta(hours=2))
    administration._copie_externe()

    alertes = _alertes()
    assert len(alertes) == 2 and "de nouveau copiée" in alertes[-1]
    assert un("SELECT count(*) FROM alerte_admin WHERE reglee_le IS NULL") == 0
    assert "Dernière copie hors du serveur" in administration.etat()
