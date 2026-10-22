-- =============================================================================
-- 076 : les règles spéciales des tâches, le rythme, la pénibilité
--                                              (CND-1 à CND-15, RAP-3, REP-3)
--
-- Rejouable.
--
-- Une tâche peut porter des règles faites de briques : des jours et des dates,
-- l'agenda, la présence (CND-3 à CND-6). Le moteur ne place une occurrence
-- qu'un jour où toutes ses règles tiennent (CND-8). Une tâche peut aussi
-- revenir N fois par semaine ou par mois au lieu de tous les N jours (CND-4).
--
-- La pénibilité arrive ici, avec les types : la répartition de la semaine
-- (REP, lot 19) la lira. Les rappels de HAL ont leur table dès maintenant, parce
-- que la base pose elle-même le rappel « règle impossible » (RAP-3) ; c'est le
-- lot 18 qui les sert.
--
-- Aucune fonction ici : elles sont dans sql/definitions/. La vérification des
-- briques est un déclencheur, et non un CHECK : un CHECK ne peut pas appeler
-- une fonction que les définitions ne chargent qu'après les migrations.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. La pénibilité                                                      (REP-3)
--
-- Sur le type, de 1 à 3 ; la tâche peut la changer, vide elle suit son type.
-- Le linge, la vaisselle et le chat sont légers ; récurer et le grand
-- nettoyage, lourds (annexe 3).
-- -----------------------------------------------------------------------------
ALTER TABLE type_tache
    ADD COLUMN IF NOT EXISTS penibilite SMALLINT NOT NULL DEFAULT 2;
ALTER TABLE type_tache DROP CONSTRAINT IF EXISTS type_tache_penibilite;
ALTER TABLE type_tache ADD CONSTRAINT type_tache_penibilite
    CHECK (penibilite BETWEEN 1 AND 3);

UPDATE type_tache SET penibilite = 1
 WHERE categorie IN ('linge', 'vaisselle', 'animal')
   AND ordre BETWEEN 1 AND 5
   AND penibilite = 2;

ALTER TABLE tache
    ADD COLUMN IF NOT EXISTS penibilite SMALLINT;
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_penibilite;
ALTER TABLE tache ADD CONSTRAINT tache_penibilite
    CHECK (penibilite IS NULL OR penibilite BETWEEN 1 AND 3);

UPDATE tache SET penibilite = 3
 WHERE code IN ('RECURAGE', 'GRAND_NETTOYAGE') AND penibilite IS NULL;

COMMENT ON COLUMN type_tache.penibilite IS
    'REP-3 : de 1 à 3. La charge d''une occurrence est sa durée multipliée par sa pénibilité.';
COMMENT ON COLUMN tache.penibilite IS
    'REP-3 : la pénibilité propre à la tâche. Vide : celle de son type.';


-- -----------------------------------------------------------------------------
-- 2. Le rythme : N fois par semaine ou par mois                         (CND-4)
--
-- Une tâche a une périodicité en jours ou un rythme. Les colonnes de
-- périodicité restent remplies pour une tâche à rythme : une dizaine de
-- fonctions les lisent (les accompagnements, une tâche déclarée faite hors
-- planning). Un déclencheur les tient à l'équivalent en jours du rythme.
-- -----------------------------------------------------------------------------
ALTER TABLE tache
    ADD COLUMN IF NOT EXISTS rythme_nombre  SMALLINT,
    ADD COLUMN IF NOT EXISTS rythme_periode VARCHAR(7),
    ADD COLUMN IF NOT EXISTS rythme_moment  VARCHAR(11) NOT NULL DEFAULT 'indifferent';

ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_rythme;
ALTER TABLE tache ADD CONSTRAINT tache_rythme CHECK (
    (rythme_nombre IS NULL) = (rythme_periode IS NULL)
    AND rythme_periode IN ('semaine', 'mois')
    AND rythme_nombre BETWEEN 1 AND CASE rythme_periode WHEN 'semaine' THEN 7 ELSE 31 END
);
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_rythme_moment;
ALTER TABLE tache ADD CONSTRAINT tache_rythme_moment
    CHECK (rythme_moment IN ('debut', 'milieu', 'fin', 'indifferent'));

COMMENT ON COLUMN tache.rythme_nombre IS
    'CND-4 : combien de fois par période. Vide : la tâche revient tous les N jours.';
COMMENT ON COLUMN tache.rythme_moment IS
    'CND-4 : le moment préféré dans la période. Essayé d''abord, sans être imposé.';


-- -----------------------------------------------------------------------------
-- 3. Les règles et leurs briques                              (CND-1 à CND-7)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS regle_tache (
    id_regle_tache        INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_tache              INTEGER      NOT NULL REFERENCES tache ON DELETE CASCADE,
    -- Ce qu'a écrit l'utilisateur. Vide pour une règle saisie brique par brique.
    phrase                TEXT,
    -- CND-2 : écrite par la base depuis les briques. C'est elle qui fait foi.
    traduction            TEXT         NOT NULL,
    validite              DATERANGE,
    chaque_annee          BOOLEAN      NOT NULL DEFAULT FALSE,
    periodicite_min_jours INTEGER,
    periodicite_max_jours INTEGER,
    rythme_nombre         SMALLINT,
    rythme_periode        VARCHAR(7),
    etat                  VARCHAR(10)  NOT NULL DEFAULT 'active',
    posee_par             INTEGER      NOT NULL REFERENCES utilisateur,
    id_demande            BIGINT       REFERENCES demande ON DELETE SET NULL,
    creee_le              TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT regle_tache_etat
        CHECK (etat IN ('active', 'suspendue', 'expiree', 'retiree')),
    CONSTRAINT regle_tache_validite_bornee
        CHECK (validite IS NULL
               OR (NOT isempty(validite) AND NOT lower_inf(validite) AND NOT upper_inf(validite))),
    -- « L'été » : une période de moins d'un an, qui revient chaque année.
    CONSTRAINT regle_tache_chaque_annee
        CHECK (NOT chaque_annee
               OR (validite IS NOT NULL AND upper(validite) - lower(validite) <= 366)),
    -- CND-7 : une fréquence de règle ne vaut que pendant sa validité, et c'est
    -- l'une ou l'autre, jamais les deux.
    CONSTRAINT regle_tache_frequence CHECK (
        (periodicite_min_jours IS NULL) = (periodicite_max_jours IS NULL)
        AND (rythme_nombre IS NULL) = (rythme_periode IS NULL)
        AND (periodicite_min_jours IS NULL OR rythme_nombre IS NULL)
        AND (validite IS NOT NULL OR (periodicite_min_jours IS NULL AND rythme_nombre IS NULL))
        AND periodicite_min_jours > 0
        AND periodicite_max_jours >= periodicite_min_jours
        AND rythme_periode IN ('semaine', 'mois')
        AND rythme_nombre BETWEEN 1 AND CASE rythme_periode WHEN 'semaine' THEN 7 ELSE 31 END
    )
);

CREATE INDEX IF NOT EXISTS regle_tache_id_tache_idx ON regle_tache (id_tache)
    WHERE etat = 'active';

COMMENT ON TABLE regle_tache IS
    'CND-1 : une règle spéciale d''une tâche. Toutes ses briques doivent tenir, et toutes les règles actives de la tâche.';
COMMENT ON COLUMN regle_tache.validite IS
    'CND-7 : la période où la règle s''applique. Vide : toujours.';


CREATE TABLE IF NOT EXISTS brique_regle (
    id_brique_regle INTEGER     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_regle_tache  INTEGER     NOT NULL REFERENCES regle_tache ON DELETE CASCADE,
    nature          VARCHAR(24) NOT NULL,
    pour_qui        VARCHAR(8),
    id_utilisateur  INTEGER     REFERENCES utilisateur,
    parametres      JSONB       NOT NULL DEFAULT '{}',

    CONSTRAINT brique_regle_une_par_nature UNIQUE (id_regle_tache, nature),
    CONSTRAINT brique_regle_nature CHECK (nature IN (
        'jours_semaine', 'dates', 'jour_du_mois', 'jours_interdits',
        'journee_vide', 'sans_cours_ni_travail', 'demi_journee', 'heures_max',
        'veille_sans_cours', 'lendemain_sans_cours', 'temps_libre_min',
        'autre_absent', 'tous_presents', 'au_retour', 'avant_depart')),
    CONSTRAINT brique_regle_pour_qui
        CHECK (pour_qui IN ('assigne', 'nomme', 'les_deux')),
    CONSTRAINT brique_regle_nomme
        CHECK ((pour_qui = 'nomme') = (id_utilisateur IS NOT NULL))
);

COMMENT ON TABLE brique_regle IS
    'CND-3 à CND-6 : une brique d''une règle. Ses paramètres sont vérifiés par motif_brique(), au déclencheur.';


-- -----------------------------------------------------------------------------
-- 4. Les rappels de HAL                                       (RAP-1 à RAP-7)
--
-- Le lot 16 n'en pose qu'une sorte, sans HAL : « règle impossible » (RAP-3),
-- que le placement rend dû en remplissant `declenche_le`. Le lot 18 les sert.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rappel_hal (
    id_rappel_hal  BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_regle_tache INTEGER      REFERENCES regle_tache ON DELETE CASCADE,
    id_tache       INTEGER      REFERENCES tache ON DELETE CASCADE,
    nature         VARCHAR(10)  NOT NULL,
    quand          TIMESTAMPTZ,
    evenement      VARCHAR(16),
    consigne       TEXT         NOT NULL,
    pose_par       VARCHAR(5)   NOT NULL,
    etat           VARCHAR(10)  NOT NULL DEFAULT 'attente',
    -- Un rappel sur événement devient dû quand l'événement arrive.
    declenche_le   TIMESTAMPTZ,
    dernier_depart DATE,
    id_appel       BIGINT       REFERENCES appel_coach ON DELETE SET NULL,
    cree_le        TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT rappel_hal_cible CHECK (id_regle_tache IS NOT NULL OR id_tache IS NOT NULL),
    CONSTRAINT rappel_hal_nature CHECK (
        (nature = 'date' AND quand IS NOT NULL AND evenement IS NULL)
        OR (nature = 'evenement' AND quand IS NULL AND evenement IN (
               'absence', 'retour', 'depart', 'emploi_du_temps', 'abandon',
               'refus', 'conflit', 'impossible', 'fin_validite'))),
    CONSTRAINT rappel_hal_consigne CHECK (length(consigne) BETWEEN 1 AND 1000),
    CONSTRAINT rappel_hal_pose_par CHECK (pose_par IN ('hal', 'base')),
    CONSTRAINT rappel_hal_etat CHECK (etat IN ('attente', 'servi', 'sans_appel', 'annule'))
);

CREATE INDEX IF NOT EXISTS rappel_hal_attente_idx ON rappel_hal (id_regle_tache)
    WHERE etat = 'attente';

COMMENT ON TABLE rappel_hal IS
    'RAP-1 : ce que le HAL du foyer devra vérifier, à une date ou sur un événement.';


-- -----------------------------------------------------------------------------
-- 5. L'occurrence garde la règle qui a décidé de son jour                (CND-8)
-- -----------------------------------------------------------------------------
ALTER TABLE occurrence
    ADD COLUMN IF NOT EXISTS id_regle_tache INTEGER
        REFERENCES regle_tache ON DELETE SET NULL;


-- -----------------------------------------------------------------------------
-- 6. La notification de fin d'une règle                                (CND-14)
-- -----------------------------------------------------------------------------
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_type_check;
ALTER TABLE notification ADD CONSTRAINT notification_type_check
    CHECK (type IN ('rappel', 'bilan', 'alerte', 'sport', 'coach', 'changement',
                    'administration', 'demande', 'regle'));


-- -----------------------------------------------------------------------------
-- 7. Les signatures qui changent
--
-- La recherche d'un jour et d'un créneau reçoit la tâche, pour lire ses règles.
-- La création d'une tâche reçoit le rythme. PostgreSQL ne remplace pas une
-- fonction dont les arguments changent : on retire l'ancienne.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS chercher_jour(INTEGER, TSTZRANGE, INTERVAL);
DROP FUNCTION IF EXISTS chercher_creneau(INTEGER, TSTZRANGE, INTERVAL, TIME, TIME, BOOLEAN, BOOLEAN);
DROP FUNCTION IF EXISTS creer_tache(TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, DATE, DATE,
                                    INTEGER, INTEGER, INTEGER, TIME, TIME, TEXT, INTEGER);
