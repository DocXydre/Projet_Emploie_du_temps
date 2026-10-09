# Les scénarios du coach

Chapitre 10.5 du dossier, section 11.3 du cahier des charges du coach.

Un scénario fixe une situation, un moment et un message, puis dit ce que le coach doit faire et ce qu'il ne doit pas faire. On ne compare pas des textes mot à mot : on vérifie des faits, c'est-à-dire les outils appelés, ce qui a été écrit en base et quelques mots obligatoires ou interdits. Le champ `a_lire` dit ce qu'un humain doit juger en relisant la réponse.

| Préfixe | Famille | Exigence |
| --- | --- | --- |
| S | Sécurité | Aucun échec toléré, sur plusieurs passages |
| D | Décision sportive | La grande majorité réussie |
| A | Application | La grande majorité réussie. Les refus de la base toujours respectés |
| T | Ton | Jugé à la lecture |

## Les rejouer

Ils tournent avec le vrai modèle, donc ils coûtent quelques centimes. Ils se jouent sur une base à part, `planif_scenarios`, créée et vidée par le script : la base de travail n'est pas touchée. Le compte utilisé est fictif.

```bash
./outils/local.sh scenarios            # tous, les S trois fois chacun
./outils/local.sh scenarios S          # une famille
./outils/local.sh scenarios S1 D2      # quelques-uns
```

À rejouer avant tout changement de modèle, de `coach/consigne.md` ou d'un chapitre de base, les scénarios de sécurité en premier (COA-14). Tout cas réel où le coach s'est trompé devient un scénario.

## Les champs

| Champ | Sens |
| --- | --- |
| `situation` | Ce que le script prépare : `plan`, `sans_plan`, `pause`, `seance_dure_validee_demain`, `seance_proposee_demain`, `seance_cle_pas_faite`, `nuit_courte`, `limitation_curl`, `voisin_secret`, `objectif_marathon` |
| `moment` | L'un des sept moments d'appel |
| `texte` | Ce que l'utilisateur écrit, s'il écrit |
| `outils_requis` | Tous doivent avoir été appelés |
| `outils_un_parmi` | Un au moins doit avoir été appelé |
| `outils_interdits` | Aucun ne doit avoir abouti |
| `base` | Des comptages à vérifier après l'appel : `egal` ou `au_moins` |
| `message_contient_un`, `message_ne_contient_pas` | Sur le message rendu, sans tenir compte de la casse |
