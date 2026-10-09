-- =============================================================================
-- 051 : le socle du coach                     (COA-1, COA-21, CAR-1, CAR-6, NOT-11)
--
-- Rejouable.
--
-- Ce qu'il faut pour qu'un appel au modèle existe et laisse une trace : le
-- réglage qui active le coach pour un compte, l'enregistrement de chaque
-- appel, les échanges, le carnet, et la trace de ce qu'une opération a écrit.
--
-- `minimum_sport` et les réservations « à déterminer » restent en place pour
-- les comptes sans coach. Leur retrait est un lot à part (annexe A du cahier
-- des charges du coach).
-- =============================================================================

-- COA-1 : le coach s'active par compte. SEC-3, PLN-14 et le score de forme
-- lisent les trois autres réglages.
ALTER TABLE utilisateur
    ADD COLUMN IF NOT EXISTS coach_actif            BOOLEAN  NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS repos_dur_heures       SMALLINT NOT NULL DEFAULT 48,
    ADD COLUMN IF NOT EXISTS seances_max_semaine    SMALLINT,
    ADD COLUMN IF NOT EXISTS besoin_sommeil_minutes SMALLINT NOT NULL DEFAULT 480;

ALTER TABLE utilisateur DROP CONSTRAINT IF EXISTS utilisateur_repos_dur_positif;
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_repos_dur_positif
    CHECK (repos_dur_heures > 0);
ALTER TABLE utilisateur DROP CONSTRAINT IF EXISTS utilisateur_seances_max_raisonnable;
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_seances_max_raisonnable
    CHECK (seances_max_semaine IS NULL OR seances_max_semaine BETWEEN 1 AND 14);
ALTER TABLE utilisateur DROP CONSTRAINT IF EXISTS utilisateur_besoin_sommeil_positif;
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_besoin_sommeil_positif
    CHECK (besoin_sommeil_minutes > 0);

-- SPT-35 : une séance peut venir du coach. « quota » reste, pour l'historique.
ALTER TABLE occurrence DROP CONSTRAINT IF EXISTS occurrence_origine_check;
ALTER TABLE occurrence ADD CONSTRAINT occurrence_origine_check
    CHECK (origine IN ('recurrence', 'manuelle', 'enchainement', 'stock', 'quota',
                       'depart', 'retour', 'coach'));

-- COA-21 : une ligne par appel au modèle, essais compris.
CREATE TABLE IF NOT EXISTS appel_coach (
    id_appel       BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur,
    moment         VARCHAR(12) NOT NULL
        CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan',
                          'signalement', 'chat')),
    declencheur    VARCHAR(12) NOT NULL
        CHECK (declencheur IN ('ordonnanceur', 'utilisateur', 'systeme')),
    operation      TEXT        NOT NULL,
    statut         VARCHAR(10) NOT NULL DEFAULT 'en_cours'
        CHECK (statut IN ('en_cours', 'termine', 'echoue')),
    essai          SMALLINT    NOT NULL DEFAULT 1 CHECK (essai > 0),
    cle_client     UUID        UNIQUE,
    debut          TIMESTAMPTZ NOT NULL DEFAULT now(),
    fin            TIMESTAMPTZ,
    tours          SMALLINT    NOT NULL DEFAULT 0 CHECK (tours >= 0),
    tokens_entree  INTEGER     NOT NULL DEFAULT 0 CHECK (tokens_entree >= 0),
    tokens_cache   INTEGER     NOT NULL DEFAULT 0 CHECK (tokens_cache >= 0),
    tokens_sortie  INTEGER     NOT NULL DEFAULT 0 CHECK (tokens_sortie >= 0),
    modele         VARCHAR(60) NOT NULL,
    motif_echec    TEXT,
    -- Les outils demandés, dans l'ordre, avec leurs arguments et le début de
    -- leur résultat. C'est ce qu'on relit pour comprendre une réponse et
    -- régler la consigne. Comme le reste de la table, seul l'administrateur le lit.
    deroule        JSONB       NOT NULL DEFAULT '[]',
    CONSTRAINT appel_clos_date CHECK (statut = 'en_cours' OR fin IS NOT NULL)
);

-- COA-22 : un compte n'a qu'un appel en cours. C'est le verrou.
CREATE UNIQUE INDEX IF NOT EXISTS appel_coach_un_seul_en_cours
    ON appel_coach (id_utilisateur) WHERE statut = 'en_cours';
ALTER TABLE appel_coach ADD COLUMN IF NOT EXISTS deroule JSONB NOT NULL DEFAULT '[]';
CREATE INDEX IF NOT EXISTS appel_coach_par_operation ON appel_coach (operation);

-- CAR-6 : tous les échanges sont gardés.
CREATE TABLE IF NOT EXISTS echange (
    id_echange      BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur  INTEGER     NOT NULL REFERENCES utilisateur,
    quand           TIMESTAMPTZ NOT NULL DEFAULT now(),
    auteur          VARCHAR(12) NOT NULL CHECK (auteur IN ('utilisateur', 'coach', 'systeme')),
    moment          VARCHAR(12) NOT NULL
        CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan',
                          'signalement', 'chat')),
    contenu         TEXT        NOT NULL CHECK (btrim(contenu) <> ''),
    id_occurrence   INTEGER     REFERENCES occurrence ON DELETE SET NULL,
    operation       TEXT,
    modele          VARCHAR(60),
    version_dossier VARCHAR(40),
    elements        JSONB       NOT NULL DEFAULT '[]',
    id_appel        BIGINT      REFERENCES appel_coach ON DELETE SET NULL,
    CONSTRAINT echange_coach_signe
        CHECK (auteur <> 'coach' OR (modele IS NOT NULL AND version_dossier IS NOT NULL)),
    CONSTRAINT echange_elements_liste CHECK (jsonb_typeof(elements) = 'array')
);
CREATE INDEX IF NOT EXISTS echange_par_compte ON echange (id_utilisateur, quand DESC);

-- NOT-11 : un type de notification porte les messages du coach.
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_type_check;
ALTER TABLE notification ADD CONSTRAINT notification_type_check
    CHECK (type IN ('rappel', 'bilan', 'alerte', 'sport', 'coach'));
ALTER TABLE notification
    ADD COLUMN IF NOT EXISTS id_echange BIGINT REFERENCES echange ON DELETE SET NULL;

-- CAR-1 : le carnet. Des notes courtes, datées, classées.
CREATE TABLE IF NOT EXISTS note_coach (
    id_note        SERIAL       PRIMARY KEY,
    id_utilisateur INTEGER      NOT NULL REFERENCES utilisateur,
    categorie      VARCHAR(12)  NOT NULL
        CHECK (categorie IN ('preference', 'efficacite', 'corps', 'engagement', 'contexte')),
    texte          VARCHAR(300) NOT NULL CHECK (btrim(texte) <> ''),
    source         VARCHAR(12)  NOT NULL CHECK (source IN ('utilisateur', 'deduction')),
    confirmee      BOOLEAN      NOT NULL,
    date_creation  DATE         NOT NULL DEFAULT CURRENT_DATE,
    -- CAR-2 : ce que l'utilisateur dit lui-même n'a pas à être confirmé.
    CONSTRAINT note_utilisateur_confirmee CHECK (source <> 'utilisateur' OR confirmee)
);
CREATE INDEX IF NOT EXISTS note_coach_par_compte ON note_coach (id_utilisateur);

-- COA-18 : ce qu'une opération a écrit, dans l'ordre. Les fonctions du coach y
-- laissent une ligne, et c'est de là que viennent les boutons d'une réponse :
-- jamais du texte du modèle. Une séance retirée y garde de quoi être nommée.
CREATE TABLE IF NOT EXISTS trace_coach (
    id_trace       BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation      TEXT        NOT NULL,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur ON DELETE CASCADE,
    quand          TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    type           VARCHAR(20) NOT NULL,
    id_objet       BIGINT,
    detail         JSONB       NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS trace_coach_par_operation ON trace_coach (operation, id_trace);
