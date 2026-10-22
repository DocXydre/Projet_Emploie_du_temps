-- =============================================================================
-- 078 : le HAL du foyer et l'aiguillage                       (HDF, AIG, lot 16)
--
-- Rejouable.
--
-- La maison a son propre HAL, commun au foyer. Il passe par le même module que
-- le HAL sport : un appel dit donc de quel HAL il est, et son verrou est par
-- compte et par HAL (HDF-7). Un échange dit de quel HAL il vient, et comment le
-- message a été aiguillé (AIG-7). La mémoire du foyer a sa table (HDF-4).
--
-- Aucune fonction ici : elles sont dans sql/definitions/.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Le HAL du foyer s'active pour le foyer                              (HDF-1)
-- -----------------------------------------------------------------------------
ALTER TABLE foyer
    ADD COLUMN IF NOT EXISTS hal_actif BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN foyer.hal_actif IS
    'HDF-1 : le HAL du foyer, commun aux membres. Actif par défaut ; l''administrateur le règle.';


-- -----------------------------------------------------------------------------
-- 2. Un appel dit de quel HAL il est                             (HDF-6, HDF-7)
-- -----------------------------------------------------------------------------
ALTER TABLE appel_coach
    ADD COLUMN IF NOT EXISTS hal      VARCHAR(6) NOT NULL DEFAULT 'sport',
    ADD COLUMN IF NOT EXISTS id_foyer INTEGER REFERENCES foyer (id_foyer);

ALTER TABLE appel_coach DROP CONSTRAINT IF EXISTS appel_coach_hal;
ALTER TABLE appel_coach ADD CONSTRAINT appel_coach_hal
    CHECK (hal IN ('sport', 'foyer') AND ((hal = 'foyer') = (id_foyer IS NOT NULL)));

ALTER TABLE appel_coach DROP CONSTRAINT IF EXISTS appel_coach_moment_check;
ALTER TABLE appel_coach ADD CONSTRAINT appel_coach_moment_check
    CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan', 'signalement',
                      'chat', 'changement', 'maison'));

-- HDF-7 : un appel en cours par compte et par HAL. On peut parler à ses deux
-- HAL en même temps, pas deux fois au même.
DROP INDEX IF EXISTS appel_coach_un_seul_en_cours;
CREATE UNIQUE INDEX IF NOT EXISTS appel_coach_un_seul_en_cours_par_hal
    ON appel_coach (id_utilisateur, hal) WHERE statut = 'en_cours';

COMMENT ON COLUMN appel_coach.hal IS
    'HDF-6 : le HAL de l''appel. « foyer » : la maison, commun au foyer ; « sport » : celui de chacun.';


-- -----------------------------------------------------------------------------
-- 3. Un échange dit de quel HAL il vient, et comment il a été aiguillé   (AIG-7)
--
-- « les_deux » : un message de l'utilisateur envoyé aux deux HAL (AIG-5). Il
-- n'est écrit qu'une fois, et chaque HAL le relit dans ses derniers échanges.
-- -----------------------------------------------------------------------------
ALTER TABLE echange
    ADD COLUMN IF NOT EXISTS hal        VARCHAR(8)  NOT NULL DEFAULT 'sport',
    ADD COLUMN IF NOT EXISTS aiguillage VARCHAR(11);

ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_hal;
ALTER TABLE echange ADD CONSTRAINT echange_hal
    CHECK (hal IN ('sport', 'foyer', 'les_deux')
           AND (hal <> 'les_deux' OR auteur = 'utilisateur'));

ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_aiguillage;
ALTER TABLE echange ADD CONSTRAINT echange_aiguillage
    CHECK (aiguillage IS NULL OR aiguillage IN ('contexte', 'mots', 'modele', 'utilisateur'));

ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_moment_check;
ALTER TABLE echange ADD CONSTRAINT echange_moment_check
    CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan', 'signalement',
                      'chat', 'changement', 'externe', 'maison'));

CREATE INDEX IF NOT EXISTS echange_par_hal ON echange (id_utilisateur, hal, id_echange);

COMMENT ON COLUMN echange.aiguillage IS
    'AIG-7 : ce qui a choisi le HAL d''un message de l''utilisateur : le contexte, les mots-clés, le petit modèle, ou l''utilisateur lui-même.';


-- -----------------------------------------------------------------------------
-- 4. La mémoire du foyer                                                (HDF-4)
--
-- Commune aux membres, comme la mémoire de HAL (MEM) mais au foyer : une ligne
-- par version, la globale et une par semaine.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS memoire_foyer (
    id_memoire      BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_foyer        INTEGER      NOT NULL REFERENCES foyer (id_foyer),
    niveau          VARCHAR(12)  NOT NULL,
    periode         DATE,
    texte           TEXT         NOT NULL,
    auteur          VARCHAR(12)  NOT NULL,
    id_auteur       INTEGER      REFERENCES utilisateur (id_utilisateur),
    couvre_jusqu_au DATE,
    quand           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    modele          VARCHAR(60),

    CONSTRAINT memoire_foyer_niveau CHECK (niveau IN ('globale', 'mois', 'semaine')),
    CONSTRAINT memoire_foyer_auteur CHECK (auteur IN ('hal', 'utilisateur', 'resume')),
    CONSTRAINT memoire_foyer_periode CHECK ((niveau = 'globale') = (periode IS NULL)),
    CONSTRAINT memoire_foyer_lundi
        CHECK (niveau <> 'semaine' OR EXTRACT(ISODOW FROM periode) = 1),
    CONSTRAINT memoire_foyer_premier
        CHECK (niveau <> 'mois' OR EXTRACT(DAY FROM periode) = 1),
    CONSTRAINT memoire_foyer_signee CHECK ((auteur = 'utilisateur') = (id_auteur IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS memoire_foyer_etage
    ON memoire_foyer (id_foyer, niveau, periode, id_memoire DESC);

COMMENT ON TABLE memoire_foyer IS
    'HDF-4 : la mémoire du HAL du foyer, commune aux membres. Une ligne par version ; la dernière d''un étage est en vigueur.';
