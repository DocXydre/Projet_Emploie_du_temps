"""Le foyer, ses invitations et les appareils                   (FOY, CNX-4, NOT-16)

Les règles vivent dans PostgreSQL : qui administre, combien de places, ce
qu'une invitation vaut. Ici, deux choses seulement que la base ne fait pas :
tirer le code d'invitation et la clé d'API au hasard, et calculer l'empreinte
du mot de passe.

`POST /invitations/{code}/accepter` et la page `GET /rejoindre/{code}` sont,
avec `/connexion`, les seules routes ouvertes sans clé : la personne invitée
n'a pas encore de compte (CNX-4).
"""

import hashlib
import re
import secrets
import string
from html import escape
from typing import Literal

from fastapi import APIRouter, HTTPException, Request, status
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from api import mot_de_passe
from api.base import executer, lister, un_seul
from api.securite import Authentifie, par_le_funnel

routeur = APIRouter(tags=["Foyer"])

# FOY-3 : dix caractères sans ceux qu'on confond à l'œil ou à la voix
# (0 et O, 1 et I, L). 30 puissance 10 : environ 2^49 codes possibles, pour un
# code qui ne vit que 48 heures et ne sert qu'une fois.
ALPHABET = "".join(c for c in string.ascii_uppercase + string.digits if c not in "01ILO")
LONGUEUR_CODE = 10


def _empreinte(code: str) -> str:
    """Le code tel qu'on le tape : sans tiret ni espace, en majuscules."""
    propre = "".join(c for c in code.upper() if c.isalnum())
    return hashlib.sha256(propre.encode()).hexdigest()


def _nouveau_code() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(LONGUEUR_CODE))


def _lisible(code: str) -> str:
    """ABCDE-FGHJK : plus facile à dicter ou à recopier."""
    return f"{code[:5]}-{code[5:]}"


# -----------------------------------------------------------------------------
# Le foyer
# -----------------------------------------------------------------------------
class ReglageFoyer(BaseModel):
    nom: str | None = Field(default=None, min_length=1, max_length=60)
    ajout_taches: Literal["tous", "admin"] | None = None
    modif_taches: Literal["tous", "admin"] | None = None


def _foyer(qui_id: int) -> dict:
    foyer = un_seul(
        """
        SELECT f.id_foyer, f.nom, f.id_administrateur, f.ajout_taches, f.modif_taches,
               f.cree_le, places_libres(f.id_foyer) AS places_libres,
               f.id_administrateur = %(moi)s AS je_suis_admin,
               droit_sur_les_taches(%(moi)s, 'ajouter') AS je_peux_ajouter,
               droit_sur_les_taches(%(moi)s, 'modifier') AS je_peux_modifier
          FROM foyer f
         WHERE f.id_foyer = foyer_de(%(moi)s)
        """,
        {"moi": qui_id},
    )
    if foyer is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "aucun_foyer", "message": "Ce compte ne fait partie d'aucun foyer"},
        )

    foyer["membres"] = lister(
        """
        SELECT u.id_utilisateur, u.pseudo, u.nom,
               u.id_utilisateur = f.id_administrateur AS administrateur
          FROM utilisateur u
          JOIN foyer f ON f.id_foyer = u.id_foyer
         WHERE u.id_foyer = %(foyer)s AND u.actif
         ORDER BY u.id_utilisateur = f.id_administrateur DESC, u.id_utilisateur
        """,
        {"foyer": foyer["id_foyer"]},
    )
    # Les invitations en cours ne regardent que l'administrateur, qui peut les
    # annuler. Le code n'y figure pas : il n'est montré qu'à sa création.
    foyer["invitations"] = lister(
        """
        SELECT id_invitation, cree_le, expire_le
          FROM invitation
         WHERE id_foyer = %(foyer)s AND servie_le IS NULL AND annulee_le IS NULL
           AND expire_le > now()
         ORDER BY cree_le
        """,
        {"foyer": foyer["id_foyer"]},
    ) if foyer["je_suis_admin"] else []
    return foyer


@routeur.get("/foyer", summary="Le foyer, ses membres et ce que chacun peut faire")
def lire_foyer(qui: Authentifie) -> dict:
    return _foyer(qui.id_utilisateur)


@routeur.patch("/foyer", summary="Renommer le foyer, régler les droits sur les tâches")
def regler_foyer(qui: Authentifie, reglage: ReglageFoyer) -> dict:
    executer(
        "SELECT regler_foyer(%(moi)s, %(nom)s, %(ajout)s, %(modif)s)",
        {"moi": qui.id_utilisateur, "nom": reglage.nom,
         "ajout": reglage.ajout_taches, "modif": reglage.modif_taches},
    )
    return _foyer(qui.id_utilisateur)


# -----------------------------------------------------------------------------
# Les invitations                                                       (FOY-3)
# -----------------------------------------------------------------------------
def _adresse(requete: Request) -> str:
    """L'adresse par laquelle l'appli joint le serveur, telle qu'elle l'a appelée.

    Derrière le funnel, Tailscale tient le HTTPS : l'API voit passer du HTTP.
    """
    schema = "https" if par_le_funnel(requete) else requete.url.scheme
    return f"{schema}://{requete.url.netloc}"


@routeur.post("/foyer/invitations", status_code=status.HTTP_201_CREATED,
              summary="Inviter quelqu'un : un code valable 48 heures, montré une fois")
def inviter(qui: Authentifie, requete: Request) -> dict:
    code = _nouveau_code()
    invitation = executer(
        "SELECT * FROM inviter_au_foyer(%(moi)s, %(empreinte)s)",
        {"moi": qui.id_utilisateur, "empreinte": _empreinte(code)},
    )
    assert invitation is not None
    lisible = _lisible(code)
    # 5.16 : le lien s'ouvre dans n'importe quel navigateur, et de là dans l'appli.
    return {**invitation, "code": lisible, "serveur": _adresse(requete),
            "lien": f"{_adresse(requete)}/rejoindre/{lisible}"}


# La page d'un lien d'invitation : elle ne lit rien en base, et ne dit donc pas
# si le code vaut encore. C'est l'appli qui le saura, en l'acceptant.
FORME_CODE = re.compile(r"[A-Za-z0-9]{5}-?[A-Za-z0-9]{5}")

PAGE_INVITATION = """<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Rejoindre un foyer dans HAL</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
         background: radial-gradient(circle at 30% 20%, #2b2f55, #0d0f1a 70%);
         font: 17px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
         color: #fff; }
  main { max-width: 360px; padding: 32px 24px; text-align: center; }
  h1 { font-size: 28px; margin: 0 0 8px; }
  p { color: rgba(255,255,255,.72); margin: 0 0 20px; }
  .code { font: 600 26px ui-monospace, Menlo, monospace; letter-spacing: 2px;
          padding: 14px; border-radius: 18px; background: rgba(255,255,255,.08);
          border: 1px solid rgba(255,255,255,.24); margin: 0 0 24px; }
  a.bouton { display: block; padding: 16px; border-radius: 999px; background: #5ce1c5;
             color: #0a0f14; font-weight: 600; text-decoration: none; margin-bottom: 16px; }
  small { color: rgba(255,255,255,.5); }
</style>
</head>
<body>
<main>
  <h1>Rejoindre le foyer</h1>
  <p>On t'invite dans HAL : le planning du foyer, la maison et le sport.</p>
  <div class="code">{code}</div>
  <a class="bouton" id="ouvrir" href="hal://rejoindre?code={code}">Ouvrir dans HAL</a>
  <small>Sans l'appli, installe-la d'abord, puis touche de nouveau ce lien. Tu peux aussi
  choisir « J'ai une invitation » dans l'appli et taper ce code, avec l'adresse
  <b id="adresse"></b>. Il vaut 48 heures, une seule fois.</small>
</main>
<script>
  var serveur = window.location.origin;
  document.getElementById("adresse").textContent = window.location.host;
  document.getElementById("ouvrir").href =
    "hal://rejoindre?serveur=" + encodeURIComponent(serveur) + "&code={code}";
</script>
</body>
</html>
"""


@routeur.get("/rejoindre/{code}", response_class=HTMLResponse, include_in_schema=False)
def page_invitation(code: str) -> HTMLResponse:
    """5.16, 5.18 : le lien partagé ouvre cette page, qui ouvre l'appli avec le
    code et l'adresse du serveur déjà remplis."""
    if not FORME_CODE.fullmatch(code):
        return HTMLResponse(
            "<!doctype html><meta charset=utf-8><title>HAL</title>"
            "<p>Ce lien d'invitation n'est pas complet : demande-le de nouveau.</p>",
            status_code=status.HTTP_404_NOT_FOUND)
    propre = code.upper().replace("-", "")
    return HTMLResponse(PAGE_INVITATION.replace("{code}", escape(_lisible(propre))))


@routeur.delete("/foyer/invitations/{id_invitation}", summary="Annuler une invitation")
def annuler_invitation(id_invitation: int, qui: Authentifie) -> dict:
    executer("SELECT annuler_invitation(%(moi)s, %(id)s)",
             {"moi": qui.id_utilisateur, "id": id_invitation})
    return {"fait": True}


class Adhesion(BaseModel):
    pseudo: str = Field(min_length=3, max_length=30)
    nom: str | None = Field(default=None, max_length=50)
    mot_de_passe: str = Field(max_length=200)


@routeur.post("/invitations/{code}/accepter", status_code=status.HTTP_201_CREATED,
              summary="Rejoindre un foyer : crée le compte et rend sa clé d'API")
def accepter(code: str, adhesion: Adhesion) -> dict:
    if len(code) > 40:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"code": "invitation_invalide",
                    "message": "Ce code d'invitation n'est plus valable : demande-en un nouveau"},
        )
    try:
        mot_de_passe.valider(adhesion.mot_de_passe)
    except mot_de_passe.MotDePasseRefuse as refus:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"code": "mot_de_passe_refuse", "message": str(refus)}) from None

    cle = secrets.token_urlsafe(36)
    # La fonction est appelée seule : une jointure sur `utilisateur` l'appellerait
    # une fois par ligne, et le compte qu'elle crée n'y serait pas encore visible.
    cree = executer(
        "SELECT rejoindre_le_foyer(%(empreinte)s, %(pseudo)s, %(nom)s, %(cle)s, %(mdp)s) AS id",
        {"empreinte": _empreinte(code), "pseudo": adhesion.pseudo, "nom": adhesion.nom,
         "cle": cle, "mdp": mot_de_passe.empreinte(adhesion.mot_de_passe)},
    )
    assert cree is not None
    compte = un_seul("SELECT pseudo, cle_api FROM utilisateur WHERE id_utilisateur = %(id)s",
                     {"id": cree["id"]})
    assert compte is not None
    return compte


# -----------------------------------------------------------------------------
# Les membres                                                     (FOY-4, FOY-5)
# -----------------------------------------------------------------------------
class NouvelAdministrateur(BaseModel):
    id_utilisateur: int


@routeur.delete("/foyer/membres/{id_utilisateur}", summary="Retirer un membre du foyer")
def retirer(id_utilisateur: int, qui: Authentifie) -> dict:
    executer("SELECT retirer_du_foyer(%(moi)s, %(membre)s)",
             {"moi": qui.id_utilisateur, "membre": id_utilisateur})
    return _foyer(qui.id_utilisateur)


@routeur.post("/foyer/administrateur", summary="Passer le rôle d'administrateur du foyer")
def passer(nouveau: NouvelAdministrateur, qui: Authentifie) -> dict:
    executer("SELECT passer_administration(%(moi)s, %(membre)s)",
             {"moi": qui.id_utilisateur, "membre": nouveau.id_utilisateur})
    return _foyer(qui.id_utilisateur)


@routeur.post("/foyer/quitter", summary="Quitter le foyer")
def quitter(qui: Authentifie) -> dict:
    executer("SELECT quitter_le_foyer(%(moi)s)", {"moi": qui.id_utilisateur})
    return {"fait": True}


# -----------------------------------------------------------------------------
# Les appareils                                                  (NOT-16, CNX-6)
# -----------------------------------------------------------------------------
class Appareil(BaseModel):
    jeton: str = Field(pattern=r"^[0-9a-fA-F]{32,200}$")
    nom: str | None = Field(default=None, max_length=80)
    environnement: Literal["production", "developpement"] = "production"


@routeur.post("/moi/appareils", summary="Enregistrer l'iPhone et son jeton de notification")
def enregistrer_appareil(appareil: Appareil, qui: Authentifie) -> dict:
    # Un jeton appartient à un iPhone : s'il change de compte, il le suit.
    enregistre = executer(
        """
        INSERT INTO appareil (id_utilisateur, jeton_notification, nom, environnement)
        VALUES (%(moi)s, lower(%(jeton)s), %(nom)s, %(env)s)
        ON CONFLICT (jeton_notification) DO UPDATE
           SET id_utilisateur = EXCLUDED.id_utilisateur, nom = EXCLUDED.nom,
               environnement = EXCLUDED.environnement, vu_le = now()
        RETURNING id_appareil, nom, environnement, enregistre_le, vu_le
        """,
        {"moi": qui.id_utilisateur, "jeton": appareil.jeton, "nom": appareil.nom,
         "env": appareil.environnement},
    )
    assert enregistre is not None
    return enregistre


@routeur.delete("/moi/appareils/{jeton}", summary="Oublier un iPhone : à la déconnexion")
def oublier_appareil(jeton: str, qui: Authentifie) -> dict:
    executer(
        "DELETE FROM appareil WHERE id_utilisateur = %(moi)s AND jeton_notification = lower(%(j)s)",
        {"moi": qui.id_utilisateur, "j": jeton},
    )
    return {"fait": True}
