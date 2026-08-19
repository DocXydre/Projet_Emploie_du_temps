-- =============================================================================
-- 005 : données de référence
--
-- Ce ne sont pas des données personnelles, ce sont les règles du système :
-- les sources, les tâches récurrentes, leurs enchaînements et les articles de
-- travail. Rien ici ne doit rester secret, et rien ici n'est un identifiant.
--
-- Les comptes utilisateurs sont créés par le script d'installation, à partir de
-- variables d'environnement. Aucune clé d'API n'est écrite dans ce fichier.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Sources
--
-- Les sources automatisées sont inactives tant que leur collecteur n'existe
-- pas. La saisie manuelle suffit à faire vivre le système : c'est le mode
-- dégradé, disponible dès le premier jour.
-- -----------------------------------------------------------------------------
INSERT INTO source (code, libelle, mode_collecte, frequence_heures, active) VALUES
    ('MANUELLE',  'Saisie manuelle',            'manuelle', 8760, TRUE),
    ('IDMC_ICS',  'Emploi du temps IDMC (ADE)', 'ics',        12, FALSE),
    ('MCDO',      'Portail McDonald''s',        'scraping',   12, FALSE);


-- -----------------------------------------------------------------------------
-- Tâches récurrentes
--
-- rappel_journee = TRUE  : à faire ce jour-là, sans heure. Événement journée
--                          entière dans le calendrier.
-- rappel_journee = FALSE : créneau horaire imposé, pour les machines.
-- -----------------------------------------------------------------------------
INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                   periodicite_min_jours, periodicite_max_jours,
                   rappel_journee, heure_min, heure_max,
                   utilise_machine, lave_uniforme, reportable) VALUES

    -- Ménage : des rappels, sans heure
    ('ASPIRATEUR',      'Passer l''aspirateur',      'menage',    4,  30,  2,  3, TRUE,  NULL,    NULL,    FALSE, FALSE, TRUE),
    ('POUSSIERE',       'Faire la poussière',        'menage',    4,  25,  7,  8, TRUE,  NULL,    NULL,    FALSE, FALSE, TRUE),
    ('RECURAGE',        'Récurer',                   'menage',    4,  40,  7,  8, TRUE,  NULL,    NULL,    FALSE, FALSE, TRUE),
    ('SALLE_DE_BAIN',   'Nettoyer la salle de bain', 'menage',    4,  45, 28, 31, TRUE,  NULL,    NULL,    FALSE, FALSE, TRUE),

    -- Litière : priorité 1, la seule chose qui ne se repousse pas
    ('LITIERE_PARTIEL', 'Litière : ramassage',       'animal',    1,  10,  2,  2, TRUE,  NULL,    NULL,    FALSE, FALSE, FALSE),
    ('LITIERE_COMPLET', 'Litière : changement',      'animal',    1,  25,  4,  4, TRUE,  NULL,    NULL,    FALSE, FALSE, FALSE),

    -- Machines : heures creuses, ressource unique
    ('LESSIVE_TRAVAIL', 'Lessive de travail',        'linge',     1,  15,  3, 14, FALSE, '21:45', '23:30', TRUE,  TRUE,  FALSE),
    ('LESSIVE_BLANC',   'Lessive de blanc',          'linge',     2,  15,  6,  8, FALSE, '21:45', '23:30', TRUE,  FALSE, TRUE),
    ('LAVE_VAISSELLE',  'Lancer le lave-vaisselle',  'vaisselle', 2,  10,  3,  4, FALSE, '21:45', '23:30', FALSE, FALSE, TRUE),

    -- Suites du linge : des rappels
    ('ETENDRE_LINGE',   'Étendre le linge',          'linge',     2,  15,  1,  1, TRUE,  NULL,    NULL,    FALSE, FALSE, TRUE),
    ('PLIER_LINGE',     'Plier et ranger le linge',  'linge',     4,  30,  1,  2, TRUE,  NULL,    NULL,    FALSE, FALSE, TRUE);


-- -----------------------------------------------------------------------------
-- Enchaînements
--
-- La règle anti-doublon est appliquée par le trigger de validation : si une
-- occurrence de la tâche suivante existe déjà dans le délai, elle est
-- repositionnée au lieu d'être dupliquée.
-- -----------------------------------------------------------------------------
INSERT INTO enchainement (id_tache_source, id_tache_suivante, delai_max_heures)
SELECT src.id_tache, cible.id_tache, 24
  FROM tache src
  JOIN tache cible ON cible.code = 'ASPIRATEUR'
 WHERE src.code IN ('POUSSIERE', 'RECURAGE');

INSERT INTO enchainement (id_tache_source, id_tache_suivante, delai_max_heures)
SELECT src.id_tache, cible.id_tache, 12
  FROM tache src
  JOIN tache cible ON cible.code = 'ETENDRE_LINGE'
 WHERE src.code IN ('LESSIVE_TRAVAIL', 'LESSIVE_BLANC');

INSERT INTO enchainement (id_tache_source, id_tache_suivante, delai_max_heures)
SELECT src.id_tache, cible.id_tache, 48
  FROM tache src
  JOIN tache cible ON cible.code = 'PLIER_LINGE'
 WHERE src.code = 'ETENDRE_LINGE';


-- -----------------------------------------------------------------------------
-- Articles de travail
--
-- Trois t-shirts, une unité couvre un jour de travail. Deux pantalons, une
-- unité couvre deux jours. Seuil de sécurité à 1 : on ne descend jamais à zéro.
-- Les durées de séchage seront à corriger après la première mauvaise surprise,
-- c'est précisément pour ça qu'elles sont en base et pas dans le code.
-- -----------------------------------------------------------------------------
INSERT INTO article_travail (code, libelle, quantite_totale, quantite_propre,
                             seuil_securite, jours_par_unite, heures_sechage) VALUES
    ('TSHIRT',   'T-shirt McDonald''s',  3, 3, 1, 1, 24),
    ('PANTALON', 'Pantalon McDonald''s', 2, 2, 1, 2, 36);
