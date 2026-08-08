-- Donnees de reference : sources de contrainte, definitions de taches et
-- chaines de dependance, telles que decrites au cahier des charges (7.1, 7.4).
--
-- Ce ne sont pas des donnees personnelles : ce sont les regles du systeme.
-- Aucun identifiant, aucun horaire reel, rien qui ne puisse etre publie.
-- Les comptes utilisateurs sont crees au demarrage a partir de l'environnement,
-- jamais par migration (cf. 9 : aucun secret dans le depot).

INSERT INTO source_contrainte (code, libelle, type_collecte, ttl_fraicheur_heures, active) VALUES
    ('SAISIE_MANUELLE', 'Saisie manuelle',                  'MANUELLE', 8760, TRUE),
    ('IDMC_ICS',        'Emploi du temps IDMC (ADE)',       'ICS',        30, FALSE),
    ('MCDO_PORTAIL',    'Portail McDonald''s',              'SCRAPING',   24, FALSE),
    ('SUAPS',           'Creneaux de piscine SUAPS',        'SCRAPING',  192, FALSE),
    ('SNCF_MAIL',       'Boite mail dediee (billets SNCF)', 'IMAP',       24, FALSE);

-- Les sources automatisees sont inactives tant que leur collecteur n'existe pas
-- (lots 2, 5, 7 et 8). SAISIE_MANUELLE suffit a faire vivre le systeme : c'est
-- le mode degrade, disponible des le premier jour.

INSERT INTO definition_tache
    (code, libelle, categorie, priorite, duree_minutes,
     intervalle_min_jours, intervalle_max_jours, gelable, fenetre_horaire_debut, fenetre_horaire_fin)
VALUES
    -- Menage recurrent (7.4 D.4)
    ('ASPIRATEUR',      'Passer l''aspirateur',        'MENAGE',    4,  30,  2,  3, TRUE,  NULL,    NULL),
    ('POUSSIERE',       'Faire la poussiere',          'MENAGE',    4,  25,  7,  8, TRUE,  NULL,    NULL),
    ('RECURAGE',        'Recurer',                     'MENAGE',    4,  40,  7,  8, TRUE,  NULL,    NULL),
    ('SALLE_DE_BAIN',   'Nettoyer la salle de bain',   'MENAGE',    4,  45, 28, 31, TRUE,  NULL,    NULL),
    ('GRAND_MENAGE',    'Grand menage',                'MENAGE',    5, 180, 28, 31, TRUE,  '13:00', '19:00'),
    -- Animal : non gelable, seule categorie qui reste due en statut MALADE (7.4 D.4)
    ('LITIERE_PARTIEL', 'Litiere : nettoyage partiel', 'ANIMAL',    1,  10,  2,  2, FALSE, NULL,    NULL),
    ('LITIERE_COMPLET', 'Litiere : changement complet','ANIMAL',    1,  25,  4,  4, FALSE, NULL,    NULL),
    -- Machines : lancement en heures creuses (7.4 D.3)
    ('LESSIVE_TRAVAIL', 'Lessive des vetements de travail', 'LINGE',    1, 15,  3, 14, FALSE, '21:45', '23:30'),
    ('LESSIVE_BLANC',   'Lessive de blanc',            'LINGE',     2,  15,  6,  8, TRUE,  '21:45', '23:30'),
    ('ETENDRE_LINGE',   'Etendre le linge',            'LINGE',     2,  15,  1,  1, FALSE, NULL,    NULL),
    ('PLIER_LINGE',     'Plier et ranger le linge',    'LINGE',     4,  30,  1,  2, TRUE,  NULL,    NULL),
    ('LAVE_VAISSELLE',  'Lancer le lave-vaisselle',    'VAISSELLE', 2,  10,  3,  4, TRUE,  '21:45', '23:30'),
    -- Sport (7.3), place par le module dedie au lot 7
    ('MUSCULATION',     'Seance de musculation',       'SPORT',     3,  90,  2,  3, TRUE,  NULL,    NULL),
    ('PISCINE',         'Seance de piscine',           'SPORT',     5,  60,  7, 14, TRUE,  '12:00', '15:00');

-- Chaines de dependance : poussiere et recurage declenchent l'aspirateur dans
-- les 24 heures. La regle anti-doublon est appliquee par le service, pas ici :
-- si une occurrence d'aspirateur existe deja dans la fenetre, elle est
-- repositionnee au lieu d'etre dupliquee (cf. 7.4 D.4).
INSERT INTO dependance_tache (definition_source_id, definition_cible_id, type, delai_max_heures)
SELECT source.id, cible.id, 'DECLENCHE_APRES', 24
FROM definition_tache source
JOIN definition_tache cible ON cible.code = 'ASPIRATEUR'
WHERE source.code IN ('POUSSIERE', 'RECURAGE');

-- Le linge : une lessive validee declenche l'etendage, qui declenche le pliage.
INSERT INTO dependance_tache (definition_source_id, definition_cible_id, type, delai_max_heures)
SELECT source.id, cible.id, 'DECLENCHE_APRES', 12
FROM definition_tache source
JOIN definition_tache cible ON cible.code = 'ETENDRE_LINGE'
WHERE source.code IN ('LESSIVE_TRAVAIL', 'LESSIVE_BLANC');

INSERT INTO dependance_tache (definition_source_id, definition_cible_id, type, delai_max_heures)
SELECT source.id, cible.id, 'DECLENCHE_APRES', 48
FROM definition_tache source
JOIN definition_tache cible ON cible.code = 'PLIER_LINGE'
WHERE source.code = 'ETENDRE_LINGE';

-- Effets des statuts (7.5 E.1). La cible de reassignation est renseignee au
-- lot 9, quand les deux comptes sont pleinement utilises.
INSERT INTO regle_statut (type_statut, categorie_tache, effet) VALUES
    ('ACTIF',  'MENAGE',    'MAINTENIR'),
    ('ACTIF',  'LINGE',     'MAINTENIR'),
    ('ACTIF',  'VAISSELLE', 'MAINTENIR'),
    ('ACTIF',  'ANIMAL',    'MAINTENIR'),
    ('ACTIF',  'SPORT',     'MAINTENIR'),
    ('ACTIF',  'ADMIN',     'MAINTENIR'),
    ('MALADE', 'MENAGE',    'REPORTER'),
    ('MALADE', 'LINGE',     'MAINTENIR'),
    ('MALADE', 'VAISSELLE', 'MAINTENIR'),
    ('MALADE', 'ANIMAL',    'MAINTENIR'),
    ('MALADE', 'SPORT',     'GELER'),
    ('MALADE', 'ADMIN',     'REPORTER'),
    ('ABSENT', 'MENAGE',    'GELER'),
    ('ABSENT', 'LINGE',     'GELER'),
    ('ABSENT', 'VAISSELLE', 'GELER'),
    ('ABSENT', 'ANIMAL',    'MAINTENIR'),
    ('ABSENT', 'SPORT',     'GELER'),
    ('ABSENT', 'ADMIN',     'MAINTENIR');
