# Anciennes fonctionnalités

Ce qui a servi, ne sert plus, et pourrait resservir. Chaque dossier garde le code
retiré tel qu'il était, avec de quoi le remettre en service.

Rien ici n'est importé par l'API, collecté par pytest ni copié dans l'image
Docker : `testpaths` pointe sur `tests/`, le Dockerfile ne copie que `api/` et
`outils/`, et ruff ignore le dossier.

| Dossier | Retiré le | Pourquoi |
|---|---|---|
| `stock_uniforme/` | septembre 2026 | Fin du contrat McDonald's : plus d'uniforme à compter ni à laver |
| `reservations_sport/` | octobre 2026 | HAL propose les séances de chacun : plus de réservations « à déterminer », d'habitudes ni de minimum |
| `bot_des_membres/` | octobre 2026 | Tout se fait dans l'appli HAL ; le bot ne sert plus qu'à l'administration |
