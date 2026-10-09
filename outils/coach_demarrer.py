"""Prépare un compte pour le coach, à partir d'un fichier.        (opération C0)

    docker exec -i planif-api python -m outils.coach_demarrer < local/demarrage.json

Le profil, le dépistage, les lieux, les limitations et les exercices qu'elles
interdisent. Ce fichier contient des données de santé : il vit dans `local/`,
qui n'est pas versionné, et jamais dans le dépôt (EXO-9).

Rejouable : le profil et les lieux sont remplacés, une limitation de même
libellé est mise à jour, un dépistage identique au dernier n'est pas réinscrit.
"""

import json
import sys

from api import operation
from api.base import arreter_pool, executer, lister, un_seul
from api.coach import contexte
from api.routeurs import coach as routes
from api.securite import Appelant


def main() -> int:
    donnees = json.load(sys.stdin)
    pseudo = donnees.get("pseudo")
    compte = un_seul("SELECT id_utilisateur, pseudo, role FROM utilisateur "
                     "WHERE pseudo = %(p)s AND actif", {"p": pseudo})
    if compte is None:
        print(f"Compte « {pseudo} » inconnu.")
        return 2
    qui = Appelant(**compte)
    u = qui.id_utilisateur

    with operation.ouvrir("démarrage du coach", acteur=pseudo):
        if donnees.get("profil"):
            if "AAAA" in str(donnees["profil"].get("date_naissance", "")):
                print("Remplis d'abord la date de naissance dans le fichier.")
                return 2
            routes.ecrire_profil(qui, routes.Profil(**donnees["profil"]))
            print("Profil enregistré.")

        if donnees.get("depistage"):
            dernier = contexte.depistage(u) or {}
            if any(dernier.get(q) != v for q, v in donnees["depistage"].items()
                   if q in routes.QUESTIONS_DEPISTAGE) or not dernier:
                routes.repondre_depistage(qui, routes.Depistage(**donnees["depistage"]))
            etat = contexte.depistage(u)
            print("Dépistage : " + (etat["bloque"] or "il ne bloque rien."))

        codes = {ligne["code"]: ligne["id_lieu"]
                 for ligne in lister("SELECT code, id_lieu FROM lieu_sport")}
        for discipline, lieux in (donnees.get("lieux") or {}).items():
            inconnus = [c for c in lieux if c not in codes]
            if inconnus:
                print(f"Lieux inconnus pour {discipline} : {inconnus}. Connus : {list(codes)}")
                return 2
            routes.choisir_lieux(qui, discipline, [codes[c] for c in lieux])
            print(f"Lieux de {discipline} : {', '.join(lieux)}.")

        for limitation in donnees.get("limitations") or []:
            interdits = limitation.pop("interdits", [])
            existante = un_seul(
                "SELECT id_limitation FROM limitation WHERE id_utilisateur = %(u)s "
                "AND libelle = %(l)s", {"u": u, "l": limitation["libelle"]})
            if existante:
                identifiant = existante["id_limitation"]
                routes.modifier_limitation(qui, identifiant,
                                           routes.LimitationModifiee(**limitation))
            else:
                identifiant = routes.declarer_limitation(
                    qui, routes.Limitation(**limitation))["id_limitation"]
            routes.remplacer_interdits(qui, identifiant,
                                       [routes.Interdit(**i) for i in interdits])
            print(f"Limitation « {limitation['libelle']} » : {len(interdits)} exercice(s) "
                  "interdit(s).")

        for reglage in ("seances_max_semaine", "repos_dur_heures", "besoin_sommeil_minutes"):
            if reglage in donnees:
                # Le nom de la colonne vient de la liste ci-dessus, pas du fichier.
                executer(f"UPDATE utilisateur SET {reglage} = %(v)s "
                         "WHERE id_utilisateur = %(u)s", {"v": donnees[reglage], "u": u})

        if donnees.get("activer"):
            executer("SELECT activer_coach(%(u)s, TRUE)", {"u": u})
            print("Coach activé.")

    manques = contexte.ce_qui_manque(u)
    print("Il manque encore : " + " ; ".join(manques) if manques
          else "Tout est prêt pour un premier plan.")
    return 0


if __name__ == "__main__":
    code = main()
    arreter_pool()
    sys.exit(code)
