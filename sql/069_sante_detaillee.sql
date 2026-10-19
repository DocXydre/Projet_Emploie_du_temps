-- =============================================================================
-- 069 : tout le détail de Santé                              (SAN-11 à SAN-16)
--
-- Rejouable.
--
-- Jusqu'ici, une séance de la montre n'était qu'un résumé : durée, distance,
-- FC moyenne. HAL ne pouvait pas découper une course. Tout ce que Santé donne
-- est maintenant gardé, brut, dans des tables à part :
--
--   activite_serie     chaque mesure prise pendant une séance (FC, vitesse,
--                      cadence, puissance, foulée, contact au sol, oscillation)
--   activite_segment   les kilomètres, les étapes, les tours et les pauses
--   activite_trace     le tracé GPS, point par point
--   echantillon_sante  le quotidien, mesure par mesure (FC de la journée, VFC,
--                      VO2max, FC de récupération, poids, SpO2, respiration,
--                      température du poignet, énergie active)
--   sommeil_phase      le sommeil, phase par phase
--
-- Les bornes de chaque grandeur sont des données (grandeur_sante) : une mesure
-- hors bornes est écartée à la réception, pas le lot entier.
--
-- Une même séance enregistrée par deux applications (la montre et Strava) n'est
-- comptée qu'une fois : l'autre garde son détail mais pointe vers celle qui
-- compte (doublon_de).
-- =============================================================================

-- SAN-12 : chaque grandeur, son unité et ses bornes plausibles.
CREATE TABLE IF NOT EXISTS grandeur_sante (
    code     VARCHAR(24) PRIMARY KEY,
    libelle  VARCHAR(60) NOT NULL,
    unite    VARCHAR(12) NOT NULL,
    portee   VARCHAR(10) NOT NULL CHECK (portee IN ('seance', 'quotidien', 'les_deux')),
    minimum  DOUBLE PRECISION NOT NULL,
    maximum  DOUBLE PRECISION NOT NULL,
    CHECK (minimum < maximum)
);

INSERT INTO grandeur_sante (code, libelle, unite, portee, minimum, maximum) VALUES
    ('fc',                  'Fréquence cardiaque',            'bpm',       'les_deux', 25, 250),
    ('vitesse',             'Vitesse',                        'm/s',       'seance',    0, 12),
    ('cadence',             'Cadence',                        'pas/min',   'seance',    0, 300),
    ('puissance',           'Puissance de course',            'W',         'seance',    0, 2000),
    ('foulee',              'Longueur de foulée',             'm',         'seance',    0, 3),
    ('contact_sol',         'Temps de contact au sol',        'ms',        'seance',   50, 1000),
    ('oscillation',         'Oscillation verticale',          'cm',        'seance',    0, 30),
    ('distance',            'Distance',                       'm',         'seance',    0, 5000),
    ('energie',             'Énergie active',                 'kcal',      'les_deux',  0, 5000),
    ('pas',                 'Pas',                            'pas',       'quotidien', 0, 100000),
    ('fc_repos',            'FC au repos',                    'bpm',       'quotidien', 25, 150),
    ('vfc',                 'Variabilité cardiaque (SDNN)',   'ms',        'quotidien', 1, 300),
    ('vo2max',              'VO2max',                         'ml/kg/min', 'quotidien', 10, 95),
    ('fc_recuperation',     'FC de récupération à 1 min',     'bpm',       'quotidien', 0, 120),
    ('poids',               'Poids',                          'kg',        'quotidien', 25, 300),
    ('spo2',                'Saturation en oxygène',          '%',         'quotidien', 50, 100),
    ('respiration',         'Fréquence respiratoire',         '/min',      'quotidien', 4, 60),
    ('temperature_poignet', 'Température du poignet la nuit', '°C',        'quotidien', 30, 42)
ON CONFLICT (code) DO UPDATE
   SET libelle = EXCLUDED.libelle, unite = EXCLUDED.unite, portee = EXCLUDED.portee,
       minimum = EXCLUDED.minimum, maximum = EXCLUDED.maximum;

-- SAN-11 : les mesures d'une séance, telles que la montre les a prises. Une
-- mesure ponctuelle (la FC) n'a pas de fin ; une mesure sur un intervalle (la
-- distance, la vitesse) en a une.
CREATE TABLE IF NOT EXISTS activite_serie (
    id_activite BIGINT      NOT NULL REFERENCES activite_sante ON DELETE CASCADE,
    grandeur    VARCHAR(24) NOT NULL REFERENCES grandeur_sante,
    debut       TIMESTAMPTZ NOT NULL,
    fin         TIMESTAMPTZ CHECK (fin >= debut),
    valeur      DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (id_activite, grandeur, debut)
);

-- SAN-13 : le découpage d'une séance. Une étape porte ce que HAL avait prévu
-- (MON-1) ; un kilomètre, sa distance.
CREATE TABLE IF NOT EXISTS activite_segment (
    id_activite BIGINT      NOT NULL REFERENCES activite_sante ON DELETE CASCADE,
    sorte       VARCHAR(10) NOT NULL CHECK (sorte IN ('kilometre', 'etape', 'tour', 'pause')),
    rang        SMALLINT    NOT NULL CHECK (rang >= 1),
    periode     TSTZRANGE   NOT NULL CHECK (NOT isempty(periode)),
    distance_m  NUMERIC(8,1) CHECK (distance_m >= 0),
    libelle     VARCHAR(60),
    prevu       JSONB,
    details     JSONB       NOT NULL DEFAULT '{}',
    PRIMARY KEY (id_activite, sorte, rang)
);

-- SAN-14 : le tracé GPS. Il ne sort du serveur que vers le modèle (SAN-7).
CREATE TABLE IF NOT EXISTS activite_trace (
    id_activite BIGINT       NOT NULL REFERENCES activite_sante ON DELETE CASCADE,
    instant     TIMESTAMPTZ  NOT NULL,
    latitude    NUMERIC(9,6) NOT NULL CHECK (latitude BETWEEN -90 AND 90),
    longitude   NUMERIC(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    altitude_m  NUMERIC(6,1),
    precision_m NUMERIC(6,1) CHECK (precision_m >= 0),
    vitesse_ms  NUMERIC(5,2) CHECK (vitesse_ms >= 0),
    PRIMARY KEY (id_activite, instant)
);

-- SAN-15 : le quotidien, mesure par mesure, avec sa source. Rien n'est jeté :
-- la lecture prend la montre d'abord quand deux sources disent la même chose.
CREATE TABLE IF NOT EXISTS echantillon_sante (
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur,
    cle_externe    VARCHAR(64) NOT NULL,
    grandeur       VARCHAR(24) NOT NULL REFERENCES grandeur_sante,
    periode        TSTZRANGE   NOT NULL CHECK (lower(periode) IS NOT NULL),
    valeur         DOUBLE PRECISION NOT NULL,
    source         VARCHAR(80),
    appareil       VARCHAR(40),
    de_la_montre   BOOLEAN GENERATED ALWAYS AS (COALESCE(appareil ILIKE '%watch%', FALSE)) STORED,
    recue_le       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id_utilisateur, cle_externe)
);
CREATE INDEX IF NOT EXISTS echantillon_par_grandeur
    ON echantillon_sante (id_utilisateur, grandeur, lower(periode));

-- SAN-16 : le sommeil phase par phase.
CREATE TABLE IF NOT EXISTS sommeil_phase (
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur,
    cle_externe    VARCHAR(64) NOT NULL,
    phase          VARCHAR(10) NOT NULL
        CHECK (phase IN ('au_lit', 'endormi', 'eveille', 'leger', 'profond', 'paradoxal')),
    periode        TSTZRANGE   NOT NULL CHECK (NOT isempty(periode) AND upper(periode) IS NOT NULL),
    source         VARCHAR(80),
    appareil       VARCHAR(40),
    de_la_montre   BOOLEAN GENERATED ALWAYS AS (COALESCE(appareil ILIKE '%watch%', FALSE)) STORED,
    recue_le       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id_utilisateur, cle_externe)
);
CREATE INDEX IF NOT EXISTS sommeil_par_compte ON sommeil_phase (id_utilisateur, lower(periode));

-- SAN-15 : une séance enregistrée deux fois pointe vers celle qui compte.
ALTER TABLE activite_sante
    ADD COLUMN IF NOT EXISTS doublon_de BIGINT REFERENCES activite_sante ON DELETE SET NULL;
DO $$ BEGIN
    ALTER TABLE activite_sante ADD CONSTRAINT activite_doublon_sans_seance
        CHECK (doublon_de IS NULL OR (id_occurrence IS NULL AND doublon_de <> id_activite));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- SAN-15 : retrouver vite la mesure de la montre qui en recouvre une autre.
CREATE INDEX IF NOT EXISTS echantillon_de_la_montre
    ON echantillon_sante USING gist (id_utilisateur, grandeur, periode) WHERE de_la_montre;
