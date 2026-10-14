# Coach Santé

La bêta iPhone d'avant HAL, rangée en octobre 2026 à la bascule (lot 10 de la
partie E du cahier de HAL).

## Ce que ça faisait

Elle lisait l'application Santé (donc l'Apple Watch) et envoyait au serveur
les jours et les séances de la montre. Elle servait aussi à saisir les séances
de musculation, série par série. Tout le reste passait par le bot Telegram.

## Ce qui la remplace

L'application HAL (`ios/HAL/`) fait tout ce qu'elle faisait : la lecture de
Santé vient de son code, la saisie de musculation aussi. Elle y ajoute le
planning, la maison, les réponses de HAL avec leurs boutons, la file sans
réseau, la séance libre, la mesure et le signalement.

Les routes du serveur qu'elle appelait (`/donnees-sante/...`, `/seances/...`,
`/exercices`) restent en service : HAL s'en sert.

## Le contenu

Le projet tel qu'il était, avec son mode d'emploi dans `LISEZMOI.md`. Il se
régénère encore par `xcodegen` dans ce dossier, mais il n'est plus maintenu.
