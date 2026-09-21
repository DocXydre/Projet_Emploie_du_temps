# Stock d'uniforme : ce que disait le cahier des charges

Textes retirés de `cahier-des-charges.md` en septembre 2026, reproduits tels quels.

### Principe de conception (section 1)

- **Le cycle des vêtements de travail fait partie du socle**, et non des extensions. Il est indissociable des lessives : c'est le stock qui décide quand une machine doit tourner, et la machine à laver est une ressource unique qu'on ne peut pas mobiliser deux fois le même soir. Séparer les deux n'aurait pas de sens.

### Règles UNI (section 3.11)

### 3.11 Uniforme et stock — `UNI`

| Code | Type | Règle |
|---|---|---|
| UNI-1 | D | Un article de travail déclare sa quantité totale, un seuil de sécurité, le nombre de journées qu'une unité couvre et une durée de séchage |
| UNI-2 | D | La quantité propre ne dépasse jamais la quantité totale et ne descend jamais sous zéro |
| UNI-3 | D | Chaque changement de stock est historisé avec son type, sa quantité et sa date |
| UNI-4 | T | Chaque journée travaillée use l'uniforme : un t-shirt par service, un pantalon toutes les deux journées |
| UNI-5 | T | Le décompte porte sur des **journées travaillées**, non sur des jours de calendrier. Travailler lundi puis jeudi salit le pantalon au second service |
| UNI-6 | T | Une journée déjà comptée ne se recompte pas : la machine s'éteint, l'ordonnanceur rattrape, et rattraper ne doit rien salir en double |
| UNI-7 | T | La consommation remonte jusqu'à hier inclus, jamais aujourd'hui : un service du soir n'est pas fini le matin |
| UNI-8 | T | Un retour de linge propre remet à zéro le compteur de journées portées |
| UNI-9 | T | La quantité propre projetée est la quantité actuelle moins la consommation prévue par les services à venir |
| UNI-10 | T | Dès que la projection passe sous le seuil, une lessive est créée dont l'échéance est le service menacé, moins le séchage, moins le cycle |
| UNI-11 | T | Si cette échéance est déjà dépassée, la lessive est signalée en alerte plutôt que planifiée |
| UNI-12 | T | Deux occurrences mobilisant la machine ne sont pas placées le même jour |
| UNI-13 | T | Valider une lessive ne rend pas le linge portable : il redevient disponible à la date de validation plus la durée de séchage |
| UNI-14 | M | La quantité propre peut être recalée à la main quand le compte s'écarte de la réalité |
| UNI-15 | M | Le recalage se déclare en quantité réelle — « j'ai deux t-shirts propres » — et non en écart. L'écart est calculé et écrit au journal des mouvements, le compteur de journées portées repart de zéro |

### Diagramme entité-association : associations

    ARTICLE_TRAVAIL ||--o{ MOUVEMENT_STOCK : "historise"
    OCCURRENCE      ||--o{ MOUVEMENT_STOCK : "justifie"

### Diagramme entité-association : entités

    ARTICLE_TRAVAIL {
        serial      id_article PK
        varchar     code UK
        integer     quantite_totale
        integer     quantite_propre
        integer     seuil_securite
        integer     jours_par_unite
        integer     heures_sechage
        timestamptz disponible_le
    }
    MOUVEMENT_STOCK {
        serial      id_mouvement PK
        integer     id_article FK
        integer     id_occurrence FK
        varchar     type
        integer     quantite
        timestamptz date_mouvement
    }

### Dictionnaire : Tache.lave_uniforme

| lave_uniforme | BOOLEAN | non | implique utilise_machine | | FALSE | | |

### Dictionnaire : ArticleTravail et MouvementStock

### Table : ArticleTravail

| Attribut | Type | NULL ? | Contrainte domaine | Unicité | Défaut | PK | FK |
|---|---|---|---|---|---|---|---|
| id_article | SERIAL | non | | oui | | oui | |
| code | VARCHAR(30) | non | | oui | | | |
| libelle | VARCHAR(100) | non | | | | | |
| quantite_totale | INTEGER | non | > 0 | | | | |
| quantite_propre | INTEGER | non | entre 0 et quantite_totale | | | | |
| seuil_securite | INTEGER | non | entre 0 et quantite_totale | | 1 | | |
| jours_par_unite | INTEGER | non | > 0 | | 1 | | |
| heures_sechage | INTEGER | non | > 0 | | 24 | | |
| disponible_le | TIMESTAMPTZ | oui | | | | | |
| date_maj | TIMESTAMPTZ | non | | | now() | | |

Valeurs de départ : trois t-shirts, une unité couvre un jour de travail, séchage 24 heures ; deux pantalons, une unité couvre deux jours, séchage 36 heures. Seuil de sécurité à 1 dans les deux cas.

`disponible_le` porte la règle qui manquait à toute version naïve du problème : un vêtement lavé n'est pas un vêtement portable. Tant que cette date n'est pas atteinte, les unités en séchage ne comptent pas dans le stock utilisable.

`quantite_propre` est maintenue par trigger à chaque mouvement, jamais écrite directement par l'API.

### Table : MouvementStock

| Attribut | Type | NULL ? | Contrainte domaine | Unicité | Défaut | PK | FK |
|---|---|---|---|---|---|---|---|
| id_mouvement | SERIAL | non | | oui | | oui | |
| id_article | INTEGER | non | | | | | ArticleTravail |
| type | VARCHAR(20) | non | 'salissure', 'lavage', 'retour_propre', 'recalage' | | | | |
| quantite | INTEGER | non | ≠ 0 | | | | |
| date_mouvement | TIMESTAMPTZ | non | | | now() | | |
| id_occurrence | INTEGER | oui | | | | | Occurrence |

Chaque changement de stock laisse une ligne, comme un journal comptable. On peut donc toujours reconstituer pourquoi il ne restait qu'un t-shirt propre un mardi soir.

### Contraintes d'intégrité UNI (section 7)

| UNI-1 | `quantite_totale > 0`, `jours_par_unite > 0`, `heures_sechage > 0`, `seuil_securite` entre 0 et `quantite_totale` | Statique forte |
| UNI-2 | `quantite_propre` reste entre 0 et `quantite_totale` | Statique forte |
| UNI-3 | `quantite` d'un mouvement est non nulle ; `quantite_propre` est recalculée à chaque mouvement : trigger | Dynamique forte |
| UNI-10 | La lessive créée par le stock a la priorité 1 et n'est pas reportable | Dynamique forte |
| UNI-13 | La validation d'une lessive fixe `disponible_le` à la date de validation plus `heures_sechage` : trigger | Dynamique forte |
| UNI-13 | Les unités en séchage ne comptent pas dans le stock utilisable tant que `disponible_le` n'est pas atteint : vue | Dynamique forte |
| UNI-5 | `journees_portees` est positif ou nul, et remis à zéro à chaque mise au sale | Dynamique forte |
| UNI-6 | `dernier_jour_compte` ne recule jamais : une journée antérieure est ignorée | Dynamique forte |

### Opération 3 : projection du stock

### Opération 3 : Projection du stock de vêtements de travail

| | |
|---|---|
| **Objectif** | Déclencher une lessive assez tôt pour ne jamais se retrouver sans uniforme propre |
| **Acteurs** | Système (principal) |
| **Événement déclencheur** | Une collecte a modifié les shifts, une lessive a été validée, ou le traitement du matin s'exécute |
| **Pré-conditions** | Les articles de travail sont renseignés avec leur quantité et leur seuil |
| **Actions** | 1. Lister les journées d'occupation de type travail à venir, dans l'ordre chronologique<br>2. Partir de la quantité propre actuelle de chaque article, en excluant les unités dont la date de disponibilité n'est pas atteinte<br>3. Parcourir les journées de travail une par une et décrémenter le stock projeté selon le nombre de jours qu'une unité couvre<br>4. Repérer la première journée où le stock projeté d'un article passe sous son seuil de sécurité<br>5. Calculer l'échéance de lessive : début de ce shift, moins la durée de séchage de l'article, moins la durée du cycle<br>6. S'il n'existe pas déjà une occurrence de lessive en cours, en créer une en priorité 1, avec une fenêtre qui se termine à cette échéance |
| **Actions alternatives** | Si l'échéance calculée est déjà passée, ne pas planifier : créer une notification d'alerte immédiate. Il est trop tard pour que le linge sèche, la personne doit le savoir tout de suite plutôt que découvrir le problème au moment de partir.<br>Si aucun shift n'est connu, ne rien faire : c'est le cas quand la collecte du portail est en panne et qu'aucune saisie manuelle n'a été faite |
| **Post-conditions** | Une lessive est programmée avant la rupture, ou l'utilisateur est averti qu'elle ne peut plus l'être |

### Contrat d'API : routes du stock

Stock
  GET    /stock                           état et date de disponibilité
  GET    /stock/projection                consommation prévue et prochaine lessive
  POST   /stock/{code}/recaler            corriger la quantité propre à la main

### Bot : commandes du stock

- Commandes de consultation : planning du jour, tâches en retard, état du stock d'uniforme.
- Commandes de saisie rapide : ajouter un shift, forcer une collecte, recaler le stock.

### Opération 5, étape 6

6. Si la tâche validée est une lessive de travail, enregistrer un mouvement de stock de type lavage et fixer la date de disponibilité des articles concernés à la date réelle plus leur durée de séchage

### Opération du report d'office, cas de la lessive de travail

Une lessive de travail dont l'échéance de stock est dépassée ne se contente pas d'un report : elle déclenche une alerte, parce que le report ne résout rien
