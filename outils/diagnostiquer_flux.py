"""Que contient vraiment un flux iCalendar, et que devient-il à la collecte.

À lancer quand des occupations disparaissent du calendrier sans explication :

    docker exec planif-api python -m outils.diagnostiquer_flux MCDO

L'URL n'est jamais affichée — celle du planning de travail contient un jeton
d'accès personnel. Seule sa forme est décrite : taille, nombre d'événements,
première et dernière date.

Trois causes possibles à une disparition, et le rapport les départage :

  - le flux ne publie plus la période (l'employeur ne l'a pas encore mise en
    ligne, ou l'a retirée) : peu d'événements, dernière date proche ;
  - le flux répond mais n'est plus du calendrier (page de connexion renvoyée à
    la place) : zéro événement et un contenu qui commence par « <! » ;
  - le filtre de collecte les écarte : les événements sont là, les rejets
    disent pourquoi.

Une collecte qui ne rapporte rien EFFACE les occupations à venir de la source :
c'est le comportement voulu quand un shift est annulé, et c'est ce qui vide le
calendrier quand le flux se tait.
"""

import sys
from collections import Counter
from datetime import UTC, datetime, timedelta

from api.base import un_seul
from api.collecteurs.ics import analyser, recuperer, url_fenetre_glissante


def decrire(code: str) -> int:
    source = un_seul(
        "SELECT code, url, configuration, derniere_collecte, etat "
        "  FROM source WHERE code = %(c)s",
        {"c": code},
    )
    if source is None:
        print(f"Source {code} inconnue.")
        return 1
    if not source["url"]:
        print(f"Source {code} : aucune URL renseignée.")
        return 1

    reglages = source["configuration"] or {}
    horizon = int(reglages.get("horizon_jours", 60))
    historique = int(reglages.get("historique_jours", 7))

    print(f"Source        : {source['code']}  (état : {source['etat']})")
    print(f"Collecte      : {source['derniere_collecte']}")
    print(f"Profil        : {reglages.get('profil', 'ade')}")
    print(f"Horizon       : -{historique} j à +{horizon} j")

    # L'URL réellement appelée, avec ses éventuelles bornes recalées. On n'en
    # montre que le domaine et les noms de paramètres : les valeurs peuvent
    # être un jeton.
    appelee = url_fenetre_glissante(source["url"], horizon)
    debut_params = appelee.split("?", 1)
    noms = sorted({p.split("=")[0] for p in debut_params[1].split("&")}) \
        if len(debut_params) > 1 else []
    print(f"Domaine       : {debut_params[0].split('/')[2]}")
    print(f"Paramètres    : {', '.join(noms) or 'aucun'}")

    try:
        brut = recuperer(source["url"], horizon)
    except Exception as erreur:
        print(f"\nÉCHEC de la récupération : {type(erreur).__name__} — {erreur}")
        return 2

    print(f"\nRéponse       : {len(brut)} caractères")
    print(f"Début         : {brut[:60].strip()!r}")
    if "BEGIN:VCALENDAR" not in brut:
        print("\nCe n'est pas un calendrier. Le serveur a probablement renvoyé une")
        print("page de connexion : le lien d'abonnement a expiré.")
        return 3

    print(f"VEVENT bruts  : {brut.count('BEGIN:VEVENT')}")

    seances = analyser(brut, reglages.get("profil", "ade"))
    if not seances:
        print("\nAucun événement exploitable dans le flux.")
        return 4

    seances.sort(key=lambda s: s.debut)
    print(f"Après analyse : {len(seances)} séance(s)")
    print(f"De            : {seances[0].debut:%d/%m/%Y %H:%M}")
    print(f"À             : {seances[-1].fin:%d/%m/%Y %H:%M}")

    maintenant = datetime.now(UTC)
    plancher = maintenant - timedelta(days=historique)
    plafond = maintenant + timedelta(days=horizon)

    dedans = [s for s in seances if s.fin >= plancher and s.debut <= plafond]
    a_venir = [s for s in seances if s.debut > maintenant]

    print(f"Dans l'horizon: {len(dedans)}")
    print(f"À venir       : {len(a_venir)}")

    if a_venir:
        print("\nProchains jours publiés :")
        par_jour = Counter(s.debut.date() for s in a_venir)
        for jour in sorted(par_jour)[:20]:
            print(f"   {jour:%a %d/%m} — {par_jour[jour]} service(s)")
    else:
        print("\nLe flux ne publie AUCUN événement à venir.")
        print("C'est la cause de la disparition : une collecte qui ne ramène")
        print("rien efface les occupations futures de la source.")

    return 0


if __name__ == "__main__":
    sys.exit(decrire(sys.argv[1] if len(sys.argv) > 1 else "MCDO"))
