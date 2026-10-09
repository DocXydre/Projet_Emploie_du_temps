"""Le coach sportif.

Un module du système existant, pas un système à part : il vit dans le même
processus, la même base, et réutilise le planning, les notifications et le
journal. Il ne contient aucune règle métier. Il assemble une consigne, appelle
le modèle, exécute les outils que le modèle demande, et recommence jusqu'à la
réponse. Chaque outil d'écriture appelle une fonction SQL et rien d'autre : si
le modèle se trompe, la base refuse et lui rend le motif.

    dossier.py    les chapitres du dossier, lus dans le dépôt
    contexte.py   ce que le coach sait de l'utilisateur à chaque appel
    outils.py     la liste fermée des outils, et ceux de chaque moment
    modele.py     l'appel au fournisseur
    appel.py      la boucle : un appel, du déclencheur à la réponse
    reponse.py    la forme fixe d'une réponse et ses éléments
    planifie.py   la synthèse du soir, la révision, les essais
    telegram.py   ce que le bot affiche
"""
