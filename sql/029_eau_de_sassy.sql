-- rejouable : INSERT ... ON CONFLICT DO NOTHING. Un rejeu n'écrase pas une
-- durée ou une périodicité corrigée en base depuis.
-- -----------------------------------------------------------------------------
-- 029 — L'eau de Sassy                                                 (TAC-10)
--
-- Deux niveaux, sur le modèle de la litière : changer l'eau tous les deux
-- jours, laver la fontaine une fois par semaine. Laver la fontaine, c'est
-- forcément la remplir d'eau neuve : le lavage couvre le changement d'eau, et
-- le prochain changement repart du jour du lavage.
--
-- Priorité 1, non reportable : comme la litière, l'eau du chat ne se remet pas
-- à demain. Pas d'assigné : c'est le placement qui décide, selon qui est là.
-- -----------------------------------------------------------------------------

INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                   periodicite_min_jours, periodicite_max_jours,
                   rappel_journee, reportable)
VALUES
    ('EAU_SASSY',      'Sassy : changer l''eau',     'animal', 1,  5, 2, 2, TRUE, FALSE),
    ('FONTAINE_SASSY', 'Sassy : laver la fontaine',  'animal', 1, 10, 7, 7, TRUE, FALSE)
ON CONFLICT (code) DO NOTHING;


-- Laver la fontaine vaut changer l'eau.
INSERT INTO remplacement (id_tache_faite, id_tache_couverte)
SELECT faite.id_tache, couverte.id_tache
  FROM tache faite
  JOIN tache couverte ON couverte.code = 'EAU_SASSY'
 WHERE faite.code = 'FONTAINE_SASSY'
ON CONFLICT (id_tache_faite, id_tache_couverte) DO NOTHING;
