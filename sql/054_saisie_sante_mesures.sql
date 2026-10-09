-- =============================================================================
-- 054 : saisie d'une séance, données de santé, mesures       (SAI, SAN, MES)
--
-- Rejouable.
--
-- SAN-5 : une donnée absente n'est pas un zéro. Aucune colonne de mesure n'a
-- de valeur par défaut, et un jour sans envoi n'a pas de ligne.
-- =============================================================================

CREATE TABLE IF NOT EXISTS serie_saisie (
    id_serie           BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_occurrence      INTEGER      NOT NULL REFERENCES seance ON DELETE CASCADE,
    id_exercice        INTEGER      NOT NULL REFERENCES exercice,
    id_seance_exercice INTEGER      REFERENCES seance_exercice ON DELETE SET NULL,
    numero             SMALLINT     NOT NULL CHECK (numero > 0),
    charge_kg          NUMERIC(5,1) CHECK (charge_kg >= 0),
    repetitions        SMALLINT     CHECK (repetitions >= 0),
    duree_secondes     INTEGER      CHECK (duree_secondes > 0),
    distance_m         INTEGER      CHECK (distance_m > 0),
    marge_repetitions  SMALLINT     CHECK (marge_repetitions BETWEEN 0 AND 5),
    saisie_le          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    cle_client         UUID         NOT NULL UNIQUE,
    figee              BOOLEAN      NOT NULL DEFAULT FALSE,
    CONSTRAINT serie_numero_unique UNIQUE (id_occurrence, id_exercice, numero)
);

CREATE TABLE IF NOT EXISTS bilan_seance (
    id_occurrence INTEGER     PRIMARY KEY REFERENCES seance ON DELETE CASCADE,
    effort        SMALLINT    NOT NULL CHECK (effort BETWEEN 1 AND 10),
    duree_minutes SMALLINT    NOT NULL CHECK (duree_minutes > 0),
    commentaire   TEXT,
    date_bilan    TIMESTAMPTZ NOT NULL DEFAULT now(),
    cle_client    UUID        UNIQUE
);

CREATE TABLE IF NOT EXISTS sante_jour (
    id_utilisateur  INTEGER      NOT NULL REFERENCES utilisateur,
    jour            DATE         NOT NULL,
    pas             INTEGER      CHECK (pas >= 0),
    fc_repos        SMALLINT     CHECK (fc_repos BETWEEN 25 AND 150),
    vfc_ms          NUMERIC(5,1) CHECK (vfc_ms > 0),
    sommeil_minutes SMALLINT     CHECK (sommeil_minutes BETWEEN 0 AND 1440),
    recue_le        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (id_utilisateur, jour)
);

-- SAN-2 : rien de ce que la montre donne n'est jeté. Ce que les colonnes ne
-- nomment pas reste dans `details`.
CREATE TABLE IF NOT EXISTS activite_sante (
    id_activite    BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur,
    cle_externe    VARCHAR(64) NOT NULL,
    type           VARCHAR(40) NOT NULL,
    discipline     VARCHAR(12) NOT NULL
        CHECK (discipline IN ('musculation', 'course', 'cardio', 'autre')),
    periode        TSTZRANGE   NOT NULL
        CHECK (NOT isempty(periode) AND lower(periode) IS NOT NULL
               AND upper(periode) IS NOT NULL),
    duree_secondes INTEGER     NOT NULL CHECK (duree_secondes > 0),
    distance_m     INTEGER     CHECK (distance_m >= 0),
    denivele_m     INTEGER     CHECK (denivele_m >= 0),
    energie_kcal   INTEGER     CHECK (energie_kcal >= 0),
    fc_moyenne     SMALLINT    CHECK (fc_moyenne BETWEEN 25 AND 250),
    fc_max         SMALLINT,
    allure_s_km    SMALLINT    CHECK (allure_s_km > 0),
    cadence        SMALLINT    CHECK (cadence > 0),
    details        JSONB       NOT NULL DEFAULT '{}',
    id_occurrence  INTEGER     REFERENCES occurrence ON DELETE SET NULL,
    recue_le       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT activite_cle_unique UNIQUE (id_utilisateur, cle_externe),
    CONSTRAINT activite_fc_coherente
        CHECK (fc_max IS NULL OR fc_moyenne IS NULL OR fc_max >= fc_moyenne)
);
CREATE INDEX IF NOT EXISTS activite_par_compte ON activite_sante (id_utilisateur, periode);

CREATE TABLE IF NOT EXISTS fenetre_mesure (
    id_fenetre     SERIAL      PRIMARY KEY,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur,
    type_mesure    VARCHAR(20) NOT NULL
        CHECK (type_mesure IN ('poids', 'tour_taille', 'tour_bras', 'tour_avant_bras',
                               'tour_cuisse', 'tour_poitrine', 'test_course', 'test_force')),
    periode        DATERANGE   NOT NULL
        CHECK (NOT isempty(periode) AND upper(periode) - lower(periode) <= 7),
    statut         VARCHAR(10) NOT NULL DEFAULT 'ouverte'
        CHECK (statut IN ('ouverte', 'faite', 'reportee', 'expiree')),
    consigne       TEXT,
    id_occurrence  INTEGER     REFERENCES occurrence ON DELETE SET NULL,
    date_creation  TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- MES-5 : une seule fenêtre ouverte par compte et par type de mesure.
CREATE UNIQUE INDEX IF NOT EXISTS fenetre_une_seule_ouverte
    ON fenetre_mesure (id_utilisateur, type_mesure) WHERE statut = 'ouverte';

CREATE TABLE IF NOT EXISTS mesure (
    id_mesure      SERIAL       PRIMARY KEY,
    id_utilisateur INTEGER      NOT NULL REFERENCES utilisateur,
    type_mesure    VARCHAR(20)  NOT NULL
        CHECK (type_mesure IN ('poids', 'tour_taille', 'tour_bras', 'tour_avant_bras',
                               'tour_cuisse', 'tour_poitrine', 'test_course', 'test_force')),
    valeur         NUMERIC(8,2) NOT NULL CHECK (valeur > 0),
    unite          VARCHAR(12)  NOT NULL,
    -- Le seul endroit du module où la gauche et la droite se distinguent : on
    -- mesure un écart, on ne le programme pas (SEC-2).
    cote           VARCHAR(8)   CHECK (cote IN ('gauche', 'droite')),
    date_mesure    DATE         NOT NULL DEFAULT CURRENT_DATE CHECK (date_mesure <= CURRENT_DATE),
    id_fenetre     INTEGER      REFERENCES fenetre_mesure ON DELETE SET NULL,
    id_exercice    INTEGER      REFERENCES exercice
);
CREATE INDEX IF NOT EXISTS mesure_par_compte ON mesure (id_utilisateur, type_mesure, date_mesure);
