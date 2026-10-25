-- =============================================================================
-- 084 : lieux connus, position, soirée et météo                   (partie H)
--
-- Rejouable.
--
-- Un lieu n'est plus un nom et deux durées saisies à la main : il a une
-- adresse, des coordonnées et, pour chacun, un mode de trajet et une mémoire
-- que HAL écrit (ADR). L'iPhone dit dans quel lieu on se trouve : le serveur
-- garde le passage en cours, jamais un tracé (POS). La soirée se repère à
-- minuit (SOI). La météo se lit avant une séance dehors et après une course
-- (MTO).
--
-- Rien n'est rempli ici : les adresses se disent à HAL, et un compte sans
-- adresse ni position fonctionne exactement comme avant.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Les lieux connus                                     (ADR-1 à ADR-3, ADR-5)
--
-- Commun au foyer (le foyer, la salle, la piscine) ou à un seul compte (Lusse,
-- l'école), jamais les deux. Un lieu de séjour, d'études ou de travail est
-- toujours personnel ; le lieu du foyer, toujours commun, et seul de sa nature.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lieu_connu (
    id_lieu_connu  INTEGER       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_foyer       INTEGER       REFERENCES foyer (id_foyer),
    id_utilisateur INTEGER       REFERENCES utilisateur (id_utilisateur) ON DELETE CASCADE,
    nom            VARCHAR(60)   NOT NULL CHECK (length(btrim(nom)) > 0),
    nature         VARCHAR(10)   NOT NULL DEFAULT 'autre'
                                 CHECK (nature IN ('foyer', 'sport', 'etudes', 'travail',
                                                   'sejour', 'autre')),
    adresse        VARCHAR(200)  NOT NULL,
    latitude       NUMERIC(9,6)  NOT NULL CHECK (latitude BETWEEN -90 AND 90),
    longitude      NUMERIC(9,6)  NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    rayon_m        SMALLINT      NOT NULL DEFAULT 50 CHECK (rayon_m BETWEEN 30 AND 500),
    cree_le        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    modifie_le     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT lieu_connu_proprietaire CHECK ((id_foyer IS NULL) <> (id_utilisateur IS NULL)),
    CONSTRAINT lieu_connu_nature_proprietaire CHECK (
        (nature <> 'foyer' OR id_foyer IS NOT NULL)
        AND (nature NOT IN ('sejour', 'etudes', 'travail') OR id_utilisateur IS NOT NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS lieu_connu_nom_commun
    ON lieu_connu (id_foyer, lower(nom)) WHERE id_foyer IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS lieu_connu_nom_personnel
    ON lieu_connu (id_utilisateur, lower(nom)) WHERE id_utilisateur IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS lieu_connu_un_foyer
    ON lieu_connu (id_foyer) WHERE nature = 'foyer';

COMMENT ON TABLE lieu_connu IS
    'ADR-1 : un lieu nommé, avec son adresse et ses coordonnées. Commun au foyer, ou à un seul compte.';
COMMENT ON COLUMN lieu_connu.nature IS
    'ADR-2 : foyer, sport, études, travail, séjour (on y dort : Lusse), autre.';
COMMENT ON COLUMN lieu_connu.adresse IS
    'ADR-4 : l''adresse trouvée, telle que la Géoplateforme l''écrit.';
COMMENT ON COLUMN lieu_connu.rayon_m IS
    'ADR-3 : le cercle que l''iPhone surveille. 50 m par défaut, de 30 à 500 m.';


-- -----------------------------------------------------------------------------
-- 2. Ce que chacun en dit : le mode de trajet, la mémoire     (ADR-7, ADR-11)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lieu_de_chacun (
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur (id_utilisateur) ON DELETE CASCADE,
    id_lieu_connu  INTEGER     NOT NULL REFERENCES lieu_connu (id_lieu_connu) ON DELETE CASCADE,
    mode_trajet    VARCHAR(8)  NOT NULL CHECK (mode_trajet IN ('pied', 'velo', 'voiture')),
    PRIMARY KEY (id_utilisateur, id_lieu_connu)
);

COMMENT ON TABLE lieu_de_chacun IS
    'ADR-7 : le mode de trajet dit par chacun pour un lieu. Sans ligne, le mode par défaut.';

CREATE TABLE IF NOT EXISTS memoire_lieu (
    id_memoire_lieu BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur  INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur) ON DELETE CASCADE,
    id_lieu_connu   INTEGER      NOT NULL REFERENCES lieu_connu (id_lieu_connu) ON DELETE CASCADE,
    texte           TEXT         NOT NULL CHECK (length(texte) <= 1000),
    auteur          VARCHAR(12)  NOT NULL CHECK (auteur IN ('coach', 'hal_foyer', 'utilisateur')),
    quand           TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS memoire_lieu_en_vigueur
    ON memoire_lieu (id_utilisateur, id_lieu_connu, id_memoire_lieu DESC);

COMMENT ON TABLE memoire_lieu IS
    'ADR-11 : ce que HAL retient d''un lieu, pour un compte. Une ligne par version ; la dernière est en vigueur.';


-- -----------------------------------------------------------------------------
-- 3. Les trajets calculés                                          (ADR-8)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trajet_calcule (
    id_depart  INTEGER      NOT NULL REFERENCES lieu_connu (id_lieu_connu) ON DELETE CASCADE,
    id_arrivee INTEGER      NOT NULL REFERENCES lieu_connu (id_lieu_connu) ON DELETE CASCADE,
    mode       VARCHAR(8)   NOT NULL CHECK (mode IN ('pied', 'velo', 'voiture')),
    minutes    SMALLINT     NOT NULL CHECK (minutes >= 0),
    metres     INTEGER      NOT NULL CHECK (metres >= 0),
    estime     BOOLEAN      NOT NULL DEFAULT FALSE,
    calcule_le TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (id_depart, id_arrivee, mode),
    CHECK (id_depart <> id_arrivee)
);

COMMENT ON TABLE trajet_calcule IS
    'ADR-8 : le temps de trajet entre deux lieux connus, calculé par OSRM. estime : à vol d''oiseau, faute de calcul.';


-- -----------------------------------------------------------------------------
-- 4. Les lieux de sport et les absences gagnent un lieu connu
--                                                    (ADR-5, ADR-13, MTO-2)
-- -----------------------------------------------------------------------------
ALTER TABLE lieu_sport
    ADD COLUMN IF NOT EXISTS id_lieu_connu INTEGER REFERENCES lieu_connu (id_lieu_connu)
                                                   ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS dehors        BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN lieu_sport.id_lieu_connu IS
    'ADR-5 : l''adresse du lieu. Vide : il se pratique là où l''on est (la course dehors).';
COMMENT ON COLUMN lieu_sport.dehors IS
    'MTO-2 : une séance dehors a sa météo contrôlée une heure avant.';

UPDATE lieu_sport SET dehors = TRUE WHERE code = 'COURSE' AND NOT dehors;

ALTER TABLE absence
    ADD COLUMN IF NOT EXISTS id_lieu_connu INTEGER REFERENCES lieu_connu (id_lieu_connu)
                                                   ON DELETE SET NULL;

COMMENT ON COLUMN absence.id_lieu_connu IS
    'ADR-13 : le lieu connu où l''on est parti, en plus de son nom libre.';


-- -----------------------------------------------------------------------------
-- 5. Où l'on est                                          (POS-4, POS-6)
--
-- Une ligne par passage, sans tracé : entre deux passages, rien n'est gardé.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS presence (
    id_presence    BIGINT     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur INTEGER    NOT NULL REFERENCES utilisateur (id_utilisateur) ON DELETE CASCADE,
    id_lieu_connu  INTEGER    REFERENCES lieu_connu (id_lieu_connu) ON DELETE SET NULL,
    periode        TSTZRANGE  NOT NULL CHECK (NOT isempty(periode)),
    EXCLUDE USING gist (id_utilisateur WITH =, periode WITH &&)
);

CREATE INDEX IF NOT EXISTS presence_en_cours
    ON presence (id_utilisateur) WHERE upper_inf(periode);

COMMENT ON TABLE presence IS
    'POS-4 : un passage dans un lieu connu, ou ailleurs (id_lieu_connu vide). Ouverte : en cours.';

CREATE TABLE IF NOT EXISTS position_actuelle (
    id_utilisateur INTEGER       PRIMARY KEY REFERENCES utilisateur (id_utilisateur) ON DELETE CASCADE,
    latitude       NUMERIC(9,6)  CHECK (latitude BETWEEN -90 AND 90),
    longitude      NUMERIC(9,6)  CHECK (longitude BETWEEN -180 AND 180),
    precision_m    NUMERIC(7,1)  CHECK (precision_m >= 0),
    releve_le      TIMESTAMPTZ,
    autorisation   VARCHAR(12)   NOT NULL DEFAULT 'inconnue'
                                 CHECK (autorisation IN ('toujours', 'utilisation', 'refusee',
                                                         'inconnue')),
    precise        BOOLEAN       NOT NULL DEFAULT FALSE,
    ecrit_le       TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE position_actuelle IS
    'POS-4, POS-6 : la dernière position reçue, une par compte, écrasée à chaque envoi.';


-- -----------------------------------------------------------------------------
-- 6. Ce qui a déjà été demandé                   (POS-7 à POS-10, SOI-3, MTO-3)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS question_presence (
    id_question    BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur) ON DELETE CASCADE,
    nature         VARCHAR(10)  NOT NULL CHECK (nature IN ('sejour', 'retour', 'seance',
                                                           'cours', 'soiree', 'meteo')),
    cle            VARCHAR(40)  NOT NULL,
    posee_le       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    detail         JSONB,
    UNIQUE (id_utilisateur, nature, cle)
);

COMMENT ON TABLE question_presence IS
    'Une question de HAL ou un contrôle déjà faits, pour ne pas les refaire. cle : la présence, la séance, la demi-journée, la nuit.';


-- -----------------------------------------------------------------------------
-- 7. Les cours dits annulés                                       (POS-11)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cours_annule (
    id_source      INTEGER       NOT NULL REFERENCES source (id_source) ON DELETE CASCADE,
    cle_externe    VARCHAR(200)  NOT NULL,
    id_utilisateur INTEGER       NOT NULL REFERENCES utilisateur (id_utilisateur) ON DELETE CASCADE,
    libelle        VARCHAR(150)  NOT NULL,
    periode        TSTZRANGE     NOT NULL,
    annule_le      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (id_source, cle_externe)
);

COMMENT ON TABLE cours_annule IS
    'POS-11 : un cours dit annulé. La collecte saute sa clé, comme celle d''un conflit tranché.';


-- -----------------------------------------------------------------------------
-- 8. Les soirées                                              (SOI-1 à SOI-4)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soiree (
    id_soiree      BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur) ON DELETE CASCADE,
    nuit           DATE         NOT NULL,
    origine        VARCHAR(10)  NOT NULL CHECK (origine IN ('position', 'dite')),
    statut         VARCHAR(10)  NOT NULL DEFAULT 'probable'
                                CHECK (statut IN ('probable', 'racontee', 'ecartee')),
    verres         SMALLINT     CHECK (verres BETWEEN 0 AND 40),
    couche_a       TIMESTAMPTZ,
    ressenti       SMALLINT     CHECK (ressenti BETWEEN 1 AND 5),
    commentaire    TEXT         CHECK (length(commentaire) <= 500),
    cree_le        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    racontee_le    TIMESTAMPTZ,
    UNIQUE (id_utilisateur, nuit)
);

COMMENT ON TABLE soiree IS
    'SOI-1 à SOI-4 : une soirée, repérée à minuit ou dite à HAL, et ce qu''on en a raconté. Au compte seul.';
COMMENT ON COLUMN soiree.nuit IS 'Le jour où la soirée commence.';
COMMENT ON COLUMN soiree.ressenti IS 'De 1 (au plus mal) à 5 (en forme), le lendemain.';


-- -----------------------------------------------------------------------------
-- 9. La météo                                                (MTO-1, MTO-6, MTO-7)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meteo_heure (
    latitude      NUMERIC(5,2)  NOT NULL,
    longitude     NUMERIC(5,2)  NOT NULL,
    heure         TIMESTAMPTZ   NOT NULL,
    temperature   NUMERIC(4,1),
    ressenti      NUMERIC(4,1),
    pluie_mm      NUMERIC(5,1)  CHECK (pluie_mm >= 0),
    pluie_proba   SMALLINT      CHECK (pluie_proba BETWEEN 0 AND 100),
    vent_kmh      NUMERIC(4,1)  CHECK (vent_kmh >= 0),
    rafales_kmh   NUMERIC(4,1)  CHECK (rafales_kmh >= 0),
    direction_deg SMALLINT      CHECK (direction_deg BETWEEN 0 AND 360),
    humidite      SMALLINT      CHECK (humidite BETWEEN 0 AND 100),
    code_temps    SMALLINT,
    releve_le     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (latitude, longitude, heure)
);

COMMENT ON TABLE meteo_heure IS
    'MTO-1 : les prévisions lues chez Open-Meteo, au centième de degré, heure par heure. Effacées après 48 heures.';
COMMENT ON COLUMN meteo_heure.direction_deg IS 'D''où vient le vent, en degrés.';
COMMENT ON COLUMN meteo_heure.code_temps IS 'Le code WMO du temps, pour l''icône de l''appli.';

CREATE TABLE IF NOT EXISTS meteo_activite (
    id_activite         BIGINT        PRIMARY KEY
                                      REFERENCES activite_sante (id_activite) ON DELETE CASCADE,
    temperature         NUMERIC(4,1),
    ressenti            NUMERIC(4,1),
    humidite            SMALLINT      CHECK (humidite BETWEEN 0 AND 100),
    pluie_mm            NUMERIC(5,1)  CHECK (pluie_mm >= 0),
    vent_kmh            NUMERIC(4,1)  CHECK (vent_kmh >= 0),
    rafales_kmh         NUMERIC(4,1)  CHECK (rafales_kmh >= 0),
    direction_deg       SMALLINT      CHECK (direction_deg BETWEEN 0 AND 360),
    code_temps          SMALLINT,
    part_face           NUMERIC(4,3)  CHECK (part_face BETWEEN 0 AND 1),
    part_dos            NUMERIC(4,3)  CHECK (part_dos BETWEEN 0 AND 1),
    part_travers        NUMERIC(4,3)  CHECK (part_travers BETWEEN 0 AND 1),
    composante_face_kmh NUMERIC(4,1),
    allure_face_s       INTEGER       CHECK (allure_face_s > 0),
    allure_dos_s        INTEGER       CHECK (allure_dos_s > 0),
    releve_le           TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE meteo_activite IS
    'MTO-6, MTO-7 : la météo du départ d''une course, et le vent rapporté à son tracé.';


-- -----------------------------------------------------------------------------
-- 10. Les nouveaux moments de HAL                         (POS, SOI, MTO)
-- -----------------------------------------------------------------------------
ALTER TABLE appel_coach DROP CONSTRAINT IF EXISTS appel_coach_moment_check;
ALTER TABLE appel_coach ADD CONSTRAINT appel_coach_moment_check
    CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan', 'signalement',
                      'chat', 'changement', 'maison', 'presence', 'absent', 'soiree',
                      'meteo'));

ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_moment_check;
ALTER TABLE echange ADD CONSTRAINT echange_moment_check
    CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan', 'signalement',
                      'chat', 'changement', 'externe', 'maison', 'presence', 'absent',
                      'soiree', 'meteo'));

-- AIG-10 : une réponse à une question de HAL va au HAL qui l'a posée.
ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_aiguillage;
ALTER TABLE echange ADD CONSTRAINT echange_aiguillage
    CHECK (aiguillage IS NULL OR aiguillage IN ('contexte', 'mots', 'question', 'modele',
                                                'utilisateur'));
