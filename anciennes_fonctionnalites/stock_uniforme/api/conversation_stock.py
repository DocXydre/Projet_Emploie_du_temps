"""Fonctions du bot pour le stock d'uniforme, retirées de api/conversation.py."""

from api.base import lister, un_seul


def etat_du_stock(id_utilisateur: int) -> str:
    articles = lister("SELECT * FROM v_stock ORDER BY code")
    if not articles:
        return "Aucun article suivi."

    morceaux = []
    for article in articles:
        etat = f"{article['libelle']} : {article['quantite_propre']} propre(s)"
        if article["en_sechage"]:
            dispo = article["disponible_le"]
            etat += f", dispo le {_jour(dispo)} à {_heure(dispo)}"
        morceaux.append(etat)

    ruptures = lister("SELECT * FROM projeter_stock(%(u)s)", {"u": id_utilisateur})
    for rupture in ruptures:
        quand = rupture["jour_rupture"].strftime("%d/%m")
        if rupture["alerte"]:
            morceaux.append(f"⚠ {rupture['article']} : trop tard pour laver avant le {quand}")
        else:
            morceaux.append(f"Lessive avant le {_jour(rupture['echeance_lessive'])} "
                            f"à {_heure(rupture['echeance_lessive'])} "
                            f"(rupture le {quand})")

    return "\n".join(morceaux)


def articles_stock() -> list[dict]:
    """Les articles suivis, pour construire les boutons de recalage."""
    return lister("SELECT code, libelle, quantite_propre, quantite_totale "
                  "  FROM article_travail ORDER BY code")


def recaler_stock(code: str, propre: int) -> dict | None:
    """Déclare le stock propre réel d'un article, et replace la lessive."""
    resultat = un_seul("SELECT * FROM recaler_uniforme(%(c)s, %(q)s)",
                       {"c": code.upper(), "q": propre})
    if resultat is not None:
        from api.ordonnanceur import placer
        placer()
    return resultat
