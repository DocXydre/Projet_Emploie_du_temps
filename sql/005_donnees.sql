-- =============================================================================
-- 005 : données de référence
--
-- Sources, tâches récurrentes, enchaînements et articles de travail. Rien de
-- personnel ici : les comptes et leurs clés sont créés à l'installation, à
-- partir de variables d'environnement.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Sources
--
-- Les sources automatisées sont inactives tant que leur collecteur n'existe
-- pas. La saisie manuelle suffit à faire vivre le système : c'est le mode
-- dégradé, disponible dès le premier jour.
-- -----------------------------------------------------------------------------
INSERT INTO source (code, libelle, mode_collecte, frequence_heures, url, configuration, active) VALUES
    ('MANUELLE', 'Saisie manuelle', 'manuelle', 8760, NULL, '{}'::JSONB, TRUE),

    -- Les URL ne sont pas versionnées : celle du planning McDonald's contient
    -- un jeton d'accès personnel, et celle de l'ADE une référence d'étudiant.
    -- On les fournit au premier démarrage, par PATCH /sources/{code}, ce que le
    -- bot Telegram sait faire en collant simplement le lien.
    --
    -- Les filtres, eux, sont des données de configuration : changer de groupe au
    -- second semestre ne doit demander qu'un UPDATE, pas un redéploiement.
    --
    -- 150 jours pour l'université : le semestre entier, jusqu'en janvier. Le
    -- planning de travail, lui, n'est publié qu'à deux ou trois semaines.
    ('IDMC_ICS', 'Emploi du temps IDMC (ADE)', 'ics', 12, NULL,
     '{
        "profil": "ade",
        "type_occupation": "cours",
        "groupe": 1,
        "alternance": false,
        "langues_suivies": ["anglais", "espagnol"],
        "langues_possibles": ["anglais", "espagnol", "chinois", "allemand"],
        "horizon_jours": 150,
        "historique_jours": 7
      }'::JSONB,
     TRUE),

    ('MCDO', 'Planning McDonald''s (Easy at Work)', 'ics', 12, NULL,
     '{
        "profil": "easyatwork",
        "type_occupation": "travail",
        "horizon_jours": 30,
        "historique_jours": 7
      }'::JSONB,
     TRUE);


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

    -- Ménage : des rappels, sans heure. Les durées sont celles d'un petit
    -- appartement : ce sont des tâches de dix minutes, pas des corvées.
    ('ASPIRATEUR',      'Passer l''aspirateur',      'menage',    4,  10,  2,  3, TRUE,  NULL,    NULL,    FALSE, FALSE, TRUE),
    ('POUSSIERE',       'Faire la poussière',        'menage',    4,   5,  7,  8, TRUE,  NULL,    NULL,    FALSE, FALSE, TRUE),
    ('RECURAGE',        'Récurer',                   'menage',    4,  15,  7,  8, TRUE,  NULL,    NULL,    FALSE, FALSE, TRUE),

    -- Litière : priorité 1, la seule chose qui ne se repousse pas.
    -- Deux niveaux : le ramassage tous les deux jours, le vidage complet
    -- une fois par semaine.
    ('LITIERE_CROTTES', 'Litière : ramassage',       'animal',    1,   5,  2,  2, TRUE,  NULL,    NULL,    FALSE, FALSE, FALSE),
    ('LITIERE_VIDAGE',  'Litière : vidage complet',  'animal',    1,   5,  7,  7, TRUE,  NULL,    NULL,    FALSE, FALSE, FALSE),

    -- Machines : heures creuses, ressource unique
    ('LESSIVE_TRAVAIL', 'Lessive de travail',        'linge',     1,  15,  3, 14, FALSE, '21:45', '23:30', TRUE,  TRUE,  FALSE),
    ('LESSIVE_BLANC',   'Lessive de blanc',          'linge',     2,  15,  6,  8, FALSE, '21:45', '23:30', TRUE,  FALSE, TRUE),
    ('LAVE_VAISSELLE',  'Lancer le lave-vaisselle',  'vaisselle', 2,  10,  3,  4, FALSE, '21:45', '23:30', FALSE, FALSE, TRUE);


-- Les suites du linge n'ont de sens qu'après une machine : elles ne reviennent
-- pas d'elles-mêmes, seul l'enchaînement les fait apparaître. Sans cela,
-- « étendre le linge » tomberait tous les jours, y compris les semaines où
-- aucune lessive ne tourne.
INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                   periodicite_min_jours, periodicite_max_jours,
                   rappel_journee, recurrente) VALUES
    ('ETENDRE_LINGE', 'Étendre le linge',         'linge', 2, 15, 1, 1, TRUE, FALSE),
    ('PLIER_LINGE',   'Plier et ranger le linge', 'linge', 4, 10, 1, 2, TRUE, FALSE);


-- Vider entièrement la litière vaut ramassage : on ne fait pas les deux le
-- même jour, et le prochain ramassage repart du jour du vidage.
INSERT INTO remplacement (id_tache_faite, id_tache_couverte)
SELECT faite.id_tache, couverte.id_tache
  FROM tache faite
  JOIN tache couverte ON couverte.code = 'LITIERE_CROTTES'
 WHERE faite.code = 'LITIERE_VIDAGE';


-- Le grand nettoyage est la seule tâche qui exige deux personnes en même
-- temps. Il est donc à heure imposée, l'après-midi, et le placement cherche
-- une intersection de disponibilités au lieu d'un simple trou dans l'agenda.
INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                   periodicite_min_jours, periodicite_max_jours,
                   rappel_journee, heure_min, heure_max, requiert_les_deux) VALUES
    ('GRAND_NETTOYAGE', 'Grand nettoyage à deux', 'menage', 5, 120, 28, 31,
     FALSE, '13:00', '19:00', TRUE);


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

-- Le linge étendu le soir se plie le lendemain, pas dans la foulée : d'où un
-- délai minimum de 12 heures.
INSERT INTO enchainement (id_tache_source, id_tache_suivante, delai_min_heures, delai_max_heures)
SELECT src.id_tache, cible.id_tache, 12, 48
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
