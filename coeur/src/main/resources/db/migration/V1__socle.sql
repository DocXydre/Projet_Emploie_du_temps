-- Lot 0 : socle minimal.
-- Le modele de donnees complet (utilisateurs, occupations, taches, stock)
-- arrive au lot 1 avec les migrations V2 et suivantes.
--
-- Regles de migration pour tout le projet :
--   - une migration n'est jamais modifiee apres avoir ete appliquee ;
--   - tous les horodatages sont stockes en TIMESTAMPTZ, donc en UTC ;
--   - aucun ordre DROP destructif sans migration de reprise associee.

CREATE TABLE parametre (
    cle          VARCHAR(120) PRIMARY KEY,
    valeur       TEXT         NOT NULL,
    description  TEXT,
    modifie_le   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE parametre IS
    'Parametres modifiables sans redeploiement (cf. cahier des charges, 12 : parade a la sur-ingenierie).';

-- Parametres deja identifies dans le cahier des charges. Les valeurs sont des
-- valeurs de depart : elles seront corrigees a l usage, ce qui est precisement
-- la raison pour laquelle elles ne sont pas codees en dur.
INSERT INTO parametre (cle, valeur, description) VALUES
    ('planification.horizon_jours',          '21',    'Horizon glissant du moteur, en jours'),
    ('planification.max_deplacements',       '3',     'Backtracking limite : nombre max de deplacements'),
    ('machines.heure_creuse_debut',          '21:45', 'Heure a partir de laquelle une machine peut etre lancee'),
    ('machines.heure_creuse_fin',            '06:00', 'Fin de la plage d heures creuses'),
    ('notifications.silence_debut',          '23:30', 'Debut des heures de silence'),
    ('notifications.silence_fin',            '07:30', 'Fin des heures de silence'),
    ('deplacements.fenetre_libre_heures',    '48',    'Duree continue sans cours ni shift declenchant une proposition de trajet'),
    ('sport.quota_hebdomadaire',             '3',     'Nombre minimum de seances de musculation par semaine');
