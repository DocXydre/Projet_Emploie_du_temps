"""Stock de vêtements de travail."""

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api.base import executer, lister, un_seul
from api.securite import Authentifie

routeur = APIRouter(prefix="/stock", tags=["Stock"])


class DemandeMouvement(BaseModel):
    type: str = Field(description="salissure, lavage, retour_propre ou recalage")
    quantite: int = Field(description="Positif ; signé pour un recalage")


@routeur.get("", summary="État du stock")
def etat(qui: Authentifie) -> list[dict]:
    return lister("SELECT * FROM v_stock ORDER BY code")


@routeur.post("/consommer", summary="Compter les journées de travail passées")
def consommer(qui: Authentifie, jour: str | None = None) -> dict:
    """Salit ce qui doit l'être, en rattrapant les journées manquées.

    Un jour précis peut être forcé, ce qui sert surtout à remettre le compteur
    d'aplomb après coup. Sans argument, la fonction remonte jusqu'à hier.
    """
    if jour is not None:
        resultat = executer("SELECT consommer_uniforme(%(j)s::DATE) AS sales",
                            {"j": jour})
    else:
        resultat = executer("SELECT rattraper_uniforme() AS sales")

    return {"articles_sales": (resultat or {}).get("sales", 0)}


@routeur.get("/projection", summary="Quand tombe la rupture, et quand lancer la lessive")
def projection(qui: Authentifie) -> dict:
    lignes = lister(
        "SELECT * FROM projeter_stock(%(u)s)", {"u": qui.id_utilisateur}
    )
    return {
        "stock": lister("SELECT * FROM v_stock ORDER BY code"),
        "ruptures": lignes,
        "alerte": any(ligne["alerte"] for ligne in lignes),
    }


@routeur.post("/{code}/mouvement", status_code=status.HTTP_201_CREATED,
              summary="Enregistrer un mouvement de stock")
def mouvement(code: str, demande: DemandeMouvement, qui: Authentifie) -> dict:
    article = un_seul("SELECT id_article FROM article_travail WHERE code = %(c)s", {"c": code})
    if article is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": f"Article {code} inconnu"},
        )

    # La quantité propre n'est jamais écrite directement : elle est le résultat
    # du journal des mouvements, recalculée par trigger.
    executer(
        """
        INSERT INTO mouvement_stock (id_article, type, quantite)
        VALUES (%(article)s, %(type)s, %(quantite)s)
        """,
        {"article": article["id_article"], "type": demande.type, "quantite": demande.quantite},
    )
    resultat = un_seul("SELECT * FROM v_stock WHERE code = %(c)s", {"c": code})
    assert resultat is not None
    return resultat
