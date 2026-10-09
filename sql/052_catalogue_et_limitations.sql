-- =============================================================================
-- 052 : le catalogue d'exercices, les limitations, les lieux    (EXO, LIE, SEC-1)
--
-- Rejouable.
--
-- Les limitations d'un compte et les exercices qu'elles interdisent ne sont
-- jamais écrits ici : ce sont des données de santé, et le dépôt est public.
-- Elles s'enregistrent par l'API (EXO-9).
-- =============================================================================

CREATE TABLE IF NOT EXISTS exercice (
    id_exercice         SERIAL       PRIMARY KEY,
    code                VARCHAR(40)  NOT NULL UNIQUE,
    libelle             VARCHAR(100) NOT NULL,
    discipline          VARCHAR(12)  NOT NULL
        CHECK (discipline IN ('musculation', 'course', 'cardio')),
    groupe_principal    VARCHAR(20)  NOT NULL
        CHECK (groupe_principal IN ('pectoraux', 'dos', 'epaules', 'biceps', 'triceps',
                                    'avant_bras', 'abdominaux', 'lombaires', 'fessiers',
                                    'quadriceps', 'ischios', 'adducteurs', 'mollets',
                                    'cardio')),
    groupes_secondaires TEXT[]       NOT NULL DEFAULT '{}',
    materiel            VARCHAR(16)  NOT NULL
        CHECK (materiel IN ('machine', 'poulie', 'halteres', 'barre', 'poids_du_corps',
                            'cardio', 'aucun')),
    unilateral          BOOLEAN      NOT NULL DEFAULT FALSE,
    mesure              VARCHAR(12)  NOT NULL
        CHECK (mesure IN ('charge_reps', 'duree', 'distance')),
    consigne            TEXT,
    actif               BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS exercice_alternative (
    id_exercice    INTEGER  NOT NULL REFERENCES exercice ON DELETE CASCADE,
    id_alternative INTEGER  NOT NULL REFERENCES exercice ON DELETE CASCADE,
    rang           SMALLINT NOT NULL DEFAULT 1 CHECK (rang > 0),
    PRIMARY KEY (id_exercice, id_alternative),
    CONSTRAINT alternative_differente CHECK (id_alternative <> id_exercice)
);

CREATE TABLE IF NOT EXISTS limitation (
    id_limitation  SERIAL       PRIMARY KEY,
    id_utilisateur INTEGER      NOT NULL REFERENCES utilisateur,
    libelle        VARCHAR(100) NOT NULL,
    zone           VARCHAR(30)  NOT NULL,
    cote           VARCHAR(8)   NOT NULL CHECK (cote IN ('gauche', 'droite', 'deux')),
    description    TEXT         NOT NULL,
    active         BOOLEAN      NOT NULL DEFAULT TRUE,
    date_creation  DATE         NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE IF NOT EXISTS exercice_interdit (
    id_limitation INTEGER NOT NULL REFERENCES limitation ON DELETE CASCADE,
    id_exercice   INTEGER NOT NULL REFERENCES exercice,
    motif         TEXT    NOT NULL,
    PRIMARY KEY (id_limitation, id_exercice)
);

-- LIE-1 : où chacun pratique chaque discipline, par ordre de préférence.
CREATE TABLE IF NOT EXISTS discipline_lieu (
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur ON DELETE CASCADE,
    discipline     VARCHAR(12) NOT NULL
        CHECK (discipline IN ('musculation', 'course', 'cardio')),
    id_lieu        INTEGER     NOT NULL REFERENCES lieu_sport,
    rang           SMALLINT    NOT NULL DEFAULT 1 CHECK (rang > 0),
    PRIMARY KEY (id_utilisateur, discipline, id_lieu),
    CONSTRAINT discipline_lieu_rang_unique UNIQUE (id_utilisateur, discipline, rang)
);
