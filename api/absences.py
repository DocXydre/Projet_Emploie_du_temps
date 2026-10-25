"""Partir, rentrer, déclarer une absence                   (ABS, gel du ménage)

La base tient les règles : ce qu'une absence gèle, et à qui la charge revient
(partir_maintenant, terminer_absence et les déclencheurs de l'absence). Ce
module ne fait que les appeler et relire l'absence qui en sort.
"""

from __future__ import annotations

from datetime import datetime

from api.base import executer, un_seul


def declarer_absence(id_utilisateur: int, debut: datetime, fin: datetime,
                     lieu: str | None = None) -> dict | None:
    return executer(
        """
        INSERT INTO absence (id_utilisateur, periode, lieu, origine)
        VALUES (%(u)s, tstzrange(%(debut)s, %(fin)s, '[)'), %(lieu)s, 'manuelle')
        RETURNING id_absence, lower(periode) AS debut, upper(periode) AS fin, lieu
        """,
        {"u": id_utilisateur, "debut": debut, "fin": fin, "lieu": lieu},
    )


def partir(id_utilisateur: int, lieu: str | None = None) -> dict | None:
    """« Je pars maintenant », sans savoir quand je rentre.

    Le cas le plus fréquent, et celui qu'aucune déduction ne couvre : on monte
    en voiture, on décide sur place. L'absence court jusqu'à la prochaine
    obligation connue, et se ferme au retour.
    """
    ligne = un_seul("SELECT partir_maintenant(%(u)s, %(l)s) AS id_absence",
                    {"u": id_utilisateur, "l": lieu})
    if ligne is None:
        return None
    return un_seul(
        "SELECT id_absence, lower(periode) AS debut, upper(periode) AS fin, lieu "
        "  FROM absence WHERE id_absence = %(id)s",
        {"id": ligne["id_absence"]},
    )


def rentrer(id_utilisateur: int, instant: datetime | None = None) -> dict | None:
    """« Je suis rentré ». Ferme l'absence en cours à l'instant présent, ou à
    l'heure d'arrivée au foyer que l'iPhone a vue (POS-8).

    Rend None si aucune absence n'était en cours : ce n'est pas une erreur,
    seulement une nouvelle à annoncer autrement.
    """
    ligne = un_seul("SELECT terminer_absence(%(u)s, COALESCE(%(i)s, now())) AS id_absence",
                    {"u": id_utilisateur, "i": instant})
    if ligne is None or ligne["id_absence"] is None:
        return None

    return un_seul(
        "SELECT id_absence, lower(periode) AS debut, upper(periode) AS fin, lieu "
        "  FROM absence WHERE id_absence = %(id)s",
        {"id": ligne["id_absence"]},
    )
