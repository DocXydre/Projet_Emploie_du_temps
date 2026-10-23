"""Les réglages arrivent-ils jusqu'à l'API ?

Un réglage a trois étapes à franchir : être lu dans le `.env`, entrer dans le
conteneur, puis être compris par `api/config.py`. La deuxième était un piège :
`docker-compose.yml` recopiait les variables une à une, et un oubli ne se
voyait pas. Le réglage gardait sa valeur par défaut sans rien dire. Quatorze
étaient dans ce cas, dont toute la deuxième boîte aux lettres, livrée comme
fonctionnelle alors qu'elle ne l'était que dans les tests.

Ces tests ne lancent pas Docker. Ils lisent le fichier, ce qui suffit à
empêcher la liste de diverger à nouveau.
"""

from pathlib import Path

import pytest
import yaml

from api.config import Configuration

COMPOSE = Path(__file__).resolve().parent.parent / "docker-compose.yml"

# Ce qui n'a pas la même valeur dans le conteneur et sur la machine. Tout le
# reste doit venir du .env, sans passer par une liste à tenir à jour.
EXCEPTIONS = {"DB_HOTE", "DB_PORT", "TZ"}


@pytest.fixture(scope="module")
def service_api() -> dict:
    if not COMPOSE.exists():
        pytest.skip("docker-compose.yml absent de cette copie")
    return yaml.safe_load(COMPOSE.read_text())["services"]["api"]


def test_tout_le_env_entre_dans_le_conteneur(service_api):
    fichiers = service_api.get("env_file") or []
    if isinstance(fichiers, str):
        fichiers = [fichiers]

    assert ".env" in fichiers, (
        "Sans env_file, seules les variables recopiées dans `environment` "
        "atteignent l'API : c'est le défaut qu'on a corrigé.")


def test_aucun_reglage_n_est_recopie_a_la_main(service_api):
    recopies = set(service_api.get("environment") or {}) - EXCEPTIONS

    # Une variable listée ici écrase celle du .env. Si la liste revenait, un
    # réglage ajouté à config.py sans y figurer serait de nouveau ignoré, ou
    # pire, un repli écrit ici contredirait le défaut du code.
    assert recopies == set(), f"à retirer de docker-compose.yml : {sorted(recopies)}"


def test_la_base_reste_jointe_par_son_nom_docker(service_api):
    # Le .env décrit la machine : DB_HOTE=localhost, parfois un autre port.
    # Dans le réseau Docker la base s'appelle « db », et ces deux lignes
    # doivent l'emporter sur le .env.
    environnement = service_api["environment"]

    assert environnement["DB_HOTE"] == "db"
    assert int(environnement["DB_PORT"]) == 5432


def test_une_variable_vide_vaut_le_defaut(monkeypatch):
    # « IMAP_PORT= » dans un .env recopié de l'exemple. Convertie en entier
    # telle quelle, elle empêcherait l'API de démarrer.
    for nom in ("IMAP_PORT", "IMAP2_PORT", "HORIZON_JOURS", "ORDONNANCEUR_ACTIF"):
        monkeypatch.setenv(nom, "")

    conf = Configuration(_env_file=None)

    assert (conf.imap_port, conf.imap2_port, conf.horizon_jours) == (993, 993, 35)
    assert conf.ordonnanceur_actif is True


def test_la_deuxieme_boite_se_lit_dans_l_environnement(monkeypatch):
    for nom, valeur in {
        "IMAP_HOTE": "imap.gmail.com", "IMAP_UTILISATEUR": "t@example.org",
        "IMAP_MOT_DE_PASSE": "aaaa", "IMAP_PSEUDO": "thomas",
        "IMAP2_HOTE": "imap.gmail.com", "IMAP2_UTILISATEUR": "l@example.org",
        "IMAP2_MOT_DE_PASSE": "bbbb", "IMAP2_PSEUDO": "lorette",
    }.items():
        monkeypatch.setenv(nom, valeur)

    boites = Configuration(_env_file=None).boites

    assert [b["pseudo"] for b in boites] == ["thomas", "lorette"]
    assert boites[1]["utilisateur"] == "l@example.org"
    # Le dossier et le filtre ont un défaut : pas besoin de les écrire.
    assert (boites[1]["dossier"], boites[1]["filtre"]) == ("INBOX", "sncf")
