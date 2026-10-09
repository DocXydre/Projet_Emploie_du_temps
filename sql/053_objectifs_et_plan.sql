-- =============================================================================
-- 053 : profil, dépistage, objectifs, plan, séances, ajustements, pause
--                                              (PRO, OBJ, PLN, LIB, SEC-2, PAU)
--
-- Rejouable.
--
-- `seance` prolonge une occurrence de sport sans la remplacer : le placement,
-- la validation et l'invitation continuent de fonctionner comme avant.
--
-- SEC-2 : il n'existe ici aucune colonne pour une charge gauche et une charge
-- droite. Une différence entre les deux côtés est impossible à écrire.
-- =============================================================================

CREATE TABLE IF NOT EXISTS profil (
    id_utilisateur     INTEGER     PRIMARY KEY REFERENCES utilisateur,
    date_naissance     DATE        NOT NULL,
    sexe               VARCHAR(8)  NOT NULL CHECK (sexe IN ('homme', 'femme')),
    taille_cm          SMALLINT    NOT NULL CHECK (taille_cm BETWEEN 100 AND 250),
    niveau_musculation VARCHAR(14) NOT NULL
        CHECK (niveau_musculation IN ('debutant', 'intermediaire', 'avance')),
    niveau_course      VARCHAR(14) NOT NULL
        CHECK (niveau_course IN ('debutant', 'intermediaire', 'avance')),
    moment_prefere     VARCHAR(12) NOT NULL DEFAULT 'indifferent'
        CHECK (moment_prefere IN ('matin', 'soir', 'indifferent')),
    jours_sans_sport   SMALLINT[]  NOT NULL DEFAULT '{}'
        CHECK (jours_sans_sport <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::SMALLINT[]),
    accord_complements BOOLEAN     NOT NULL DEFAULT FALSE,
    regime             TEXT,
    date_maj           DATE        NOT NULL DEFAULT CURRENT_DATE,
    -- PRO-7 : pas de coach pour une personne de moins de 18 ans.
    CONSTRAINT profil_majeur CHECK (date_naissance <= (CURRENT_DATE - INTERVAL '18 years'))
);

-- PRO-3 : une ligne par passage du questionnaire. Le dernier fait foi.
CREATE TABLE IF NOT EXISTS depistage (
    id_depistage      SERIAL  PRIMARY KEY,
    id_utilisateur    INTEGER NOT NULL REFERENCES utilisateur,
    date_reponse      DATE    NOT NULL DEFAULT CURRENT_DATE CHECK (date_reponse <= CURRENT_DATE),
    coeur             BOOLEAN NOT NULL,
    vertiges          BOOLEAN NOT NULL,
    maladie_chronique BOOLEAN NOT NULL,
    traitement        BOOLEAN NOT NULL,
    os_articulations  BOOLEAN NOT NULL,
    grossesse         BOOLEAN NOT NULL,
    sedentaire_age    BOOLEAN NOT NULL,
    positif           BOOLEAN GENERATED ALWAYS AS
        (coeur OR vertiges OR maladie_chronique OR traitement OR os_articulations
         OR grossesse OR sedentaire_age) STORED,
    avis_medical_le   DATE,
    CONSTRAINT depistage_avis_coherent CHECK (
        avis_medical_le IS NULL
        OR ((coeur OR vertiges OR maladie_chronique OR traitement OR os_articulations
             OR grossesse OR sedentaire_age) AND avis_medical_le <= CURRENT_DATE))
);
CREATE INDEX IF NOT EXISTS depistage_par_compte
    ON depistage (id_utilisateur, date_reponse DESC, id_depistage DESC);

CREATE TABLE IF NOT EXISTS objectif (
    id_objectif      SERIAL       PRIMARY KEY,
    id_utilisateur   INTEGER      NOT NULL REFERENCES utilisateur,
    type             VARCHAR(12)  NOT NULL
        CHECK (type IN ('pilier', 'course', 'performance', 'mesure')),
    libelle          VARCHAR(120) NOT NULL,
    pilier           VARCHAR(10)  CHECK (pilier IN ('force', 'physique', 'endurance')),
    distance_m       INTEGER      CHECK (distance_m > 0),
    cible_valeur     NUMERIC(8,2),
    cible_unite      VARCHAR(12),
    id_exercice      INTEGER      REFERENCES exercice,
    type_mesure      VARCHAR(20),
    echeance         DATE,
    principal        BOOLEAN      NOT NULL DEFAULT FALSE,
    rang             SMALLINT     NOT NULL DEFAULT 1 CHECK (rang > 0),
    statut           VARCHAR(12)  NOT NULL DEFAULT 'actif'
        CHECK (statut IN ('actif', 'en_pause', 'atteint', 'abandonne')),
    avis             VARCHAR(12)  CHECK (avis IN ('realiste', 'ambitieux', 'irrealiste')),
    avis_detail      TEXT,
    feuille_de_route TEXT,
    date_creation    DATE         NOT NULL DEFAULT CURRENT_DATE,
    date_cloture     DATE,
    -- OBJ-4 : ce que chaque type exige.
    CONSTRAINT objectif_pilier      CHECK (type <> 'pilier' OR pilier IS NOT NULL),
    CONSTRAINT objectif_course      CHECK (type <> 'course'
                                           OR (distance_m IS NOT NULL AND echeance IS NOT NULL)),
    CONSTRAINT objectif_cible       CHECK (type NOT IN ('performance', 'mesure')
                                           OR cible_valeur IS NOT NULL),
    CONSTRAINT objectif_unite       CHECK (type = 'course'
                                           OR (cible_valeur IS NULL) = (cible_unite IS NULL)),
    CONSTRAINT objectif_type_mesure CHECK (type <> 'mesure' OR type_mesure IS NOT NULL),
    CONSTRAINT objectif_clos_date   CHECK (statut NOT IN ('atteint', 'abandonne')
                                           OR date_cloture IS NOT NULL)
);
-- OBJ-2 : au plus un objectif principal actif par compte.
CREATE UNIQUE INDEX IF NOT EXISTS objectif_un_principal
    ON objectif (id_utilisateur) WHERE principal AND statut = 'actif';

CREATE TABLE IF NOT EXISTS plan (
    id_plan        SERIAL      PRIMARY KEY,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur,
    id_objectif    INTEGER     NOT NULL REFERENCES objectif,
    periode        DATERANGE   NOT NULL,
    trame          TEXT        NOT NULL CHECK (btrim(trame) <> ''),
    statut         VARCHAR(10) NOT NULL DEFAULT 'en_cours' CHECK (statut IN ('en_cours', 'clos')),
    date_creation  TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- PLN-1 : quatre semaines, du lundi au dimanche.
    CONSTRAINT plan_quatre_semaines CHECK (
        upper(periode) - lower(periode) = 28
        AND EXTRACT(ISODOW FROM lower(periode)) = 1)
);
CREATE UNIQUE INDEX IF NOT EXISTS plan_un_seul_en_cours
    ON plan (id_utilisateur) WHERE statut = 'en_cours';

CREATE TABLE IF NOT EXISTS plan_semaine (
    id_plan    INTEGER     NOT NULL REFERENCES plan ON DELETE CASCADE,
    lundi      DATE        NOT NULL CHECK (EXTRACT(ISODOW FROM lundi) = 1),
    role       VARCHAR(10) NOT NULL
        CHECK (role IN ('calibrage', 'charge', 'allegee', 'test', 'affutage', 'reprise')),
    intention  TEXT,
    validee_le TIMESTAMPTZ,
    PRIMARY KEY (id_plan, lundi)
);

CREATE TABLE IF NOT EXISTS seance (
    id_occurrence            INTEGER     PRIMARY KEY REFERENCES occurrence ON DELETE CASCADE,
    id_plan                  INTEGER     REFERENCES plan ON DELETE SET NULL,
    auteur                   VARCHAR(12) NOT NULL CHECK (auteur IN ('coach', 'utilisateur')),
    etat                     VARCHAR(10) NOT NULL DEFAULT 'proposee'
        CHECK (etat IN ('proposee', 'validee')),
    libre                    BOOLEAN     NOT NULL DEFAULT FALSE,
    annoncee                 BOOLEAN     NOT NULL DEFAULT FALSE,
    discipline               VARCHAR(12) NOT NULL
        CHECK (discipline IN ('musculation', 'course', 'cardio')),
    type_seance              VARCHAR(40) NOT NULL,
    intensite                VARCHAR(8)  CHECK (intensite IN ('legere', 'moderee', 'dure')),
    cle                      BOOLEAN     NOT NULL DEFAULT FALSE,
    est_test                 BOOLEAN     NOT NULL DEFAULT FALSE,
    duree_minutes            SMALLINT    NOT NULL CHECK (duree_minutes BETWEEN 15 AND 240),
    groupes                  TEXT[]      NOT NULL DEFAULT '{}',
    consigne                 TEXT,
    id_occurrence_remplacee  INTEGER     REFERENCES occurrence ON DELETE SET NULL,
    cle_client               UUID        UNIQUE,
    avis_libre               VARCHAR(12) CHECK (avis_libre IN ('conforme', 'acceptable', 'a_eviter')),
    avis_detail              TEXT,
    -- LIB-1 : une séance libre a pour auteur l'utilisateur.
    CONSTRAINT seance_libre_utilisateur CHECK (NOT libre OR auteur = 'utilisateur'),
    CONSTRAINT seance_annoncee_libre    CHECK (NOT annoncee OR libre),
    CONSTRAINT seance_avis_libre        CHECK (avis_libre IS NULL OR libre),
    -- PLN-3 : ce qu'une séance du coach doit dire.
    CONSTRAINT seance_coach_intensite   CHECK (auteur <> 'coach' OR intensite IS NOT NULL),
    CONSTRAINT seance_coach_groupes     CHECK (auteur <> 'coach' OR cardinality(groupes) > 0)
);
CREATE INDEX IF NOT EXISTS seance_par_plan ON seance (id_plan);

CREATE TABLE IF NOT EXISTS seance_exercice (
    id_seance_exercice SERIAL       PRIMARY KEY,
    id_occurrence      INTEGER      NOT NULL REFERENCES seance ON DELETE CASCADE,
    rang               SMALLINT     NOT NULL CHECK (rang > 0),
    id_exercice        INTEGER      NOT NULL REFERENCES exercice,
    series             SMALLINT     NOT NULL DEFAULT 1 CHECK (series > 0),
    repetitions_min    SMALLINT     CHECK (repetitions_min > 0),
    repetitions_max    SMALLINT,
    charge_kg          NUMERIC(5,1) CHECK (charge_kg >= 0),
    duree_secondes     INTEGER      CHECK (duree_secondes > 0),
    distance_m         INTEGER      CHECK (distance_m > 0),
    repos_secondes     SMALLINT     CHECK (repos_secondes >= 0),
    marge_repetitions  SMALLINT     CHECK (marge_repetitions BETWEEN 0 AND 5),
    cible              VARCHAR(60),
    consigne           TEXT,
    CONSTRAINT seance_exercice_rang_unique UNIQUE (id_occurrence, rang),
    CONSTRAINT seance_exercice_fourchette
        CHECK (repetitions_max IS NULL OR repetitions_max >= COALESCE(repetitions_min, 1))
);

-- PLN-18 : pour changer une séance validée, le coach dépose un ajustement.
CREATE TABLE IF NOT EXISTS ajustement (
    id_ajustement SERIAL      PRIMARY KEY,
    id_occurrence INTEGER     NOT NULL REFERENCES seance ON DELETE CASCADE,
    nature        VARCHAR(10) NOT NULL
        CHECK (nature IN ('alleger', 'modifier', 'deplacer', 'retirer')),
    contenu       JSONB,
    motif         TEXT        NOT NULL CHECK (btrim(motif) <> ''),
    statut        VARCHAR(10) NOT NULL DEFAULT 'propose'
        CHECK (statut IN ('propose', 'accepte', 'refuse', 'caduc')),
    date_creation TIMESTAMPTZ NOT NULL DEFAULT now(),
    date_reponse  TIMESTAMPTZ,
    CONSTRAINT ajustement_contenu  CHECK (nature = 'retirer' OR contenu IS NOT NULL),
    CONSTRAINT ajustement_repondu  CHECK (statut NOT IN ('accepte', 'refuse')
                                          OR date_reponse IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS ajustement_un_seul_en_attente
    ON ajustement (id_occurrence) WHERE statut = 'propose';

-- PAU-1 : une pause du coach. Une période sans borne haute n'a pas de fin connue.
CREATE TABLE IF NOT EXISTS pause (
    id_pause       SERIAL      PRIMARY KEY,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur,
    periode        DATERANGE   NOT NULL CHECK (NOT isempty(periode)),
    motif          TEXT,
    date_creation  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE pause DROP CONSTRAINT IF EXISTS pause_sans_chevauchement;
ALTER TABLE pause ADD CONSTRAINT pause_sans_chevauchement
    EXCLUDE USING gist (id_utilisateur WITH =, periode WITH &&);
