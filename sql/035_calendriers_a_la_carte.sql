-- rejouable : ce fichier ne contient que des CREATE ... IF NOT EXISTS, des
--             CREATE OR REPLACE et des ALTER ... IF [NOT] EXISTS.
-- =============================================================================
-- 035 : des calendriers à la carte                             (NOT-5 à NOT-9)
--
-- Jusqu'ici, un compte n'avait qu'un flux : tout son planning, et rien que le
-- sien. Deux manques à l'usage.
--
-- Le premier : on veut voir le planning de l'autre. On vit à deux, savoir
-- quand l'autre est en cours ou en garde d'enfants évite de poser une question
-- par jour. Le jeton personnel ne le permettait pas.
--
-- Le second : on veut choisir ce qu'il y a dedans. Un calendrier qui mélange
-- les cours, les gardes, la litière et les séances de sport ne se lit plus.
-- Séparer « les cours de Lorette » de « nos tâches » rend les deux lisibles.
--
-- D'où un calendrier composé : une personne ou plusieurs, un contenu ou
-- plusieurs, un jeton à lui. On en crée autant qu'on veut, chacun avec son
-- adresse, et on donne l'adresse à qui la veut sans rien ouvrir d'autre.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Les contenus                                                       (NOT-6)
--
-- Six familles, et pas une par catégorie de tâche : le but est de cocher des
-- cases sur un téléphone, pas de reconstituer le modèle de données. « Tâches »
-- regroupe donc le ménage, le linge, la vaisselle, le chat et l'administratif,
-- tandis que le sport sort du lot parce qu'il se planifie à part.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contenu_de(p_nature TEXT, p_categorie TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_nature = 'proposition'                          THEN 'weekends'
        WHEN p_nature = 'occupation' AND p_categorie = 'cours'   THEN 'cours'
        WHEN p_nature = 'occupation' AND p_categorie = 'travail' THEN 'travail'
        WHEN p_nature = 'occupation'                             THEN 'perso'
        WHEN p_categorie = 'sport'                               THEN 'sport'
        ELSE 'taches'
    END;
$$;

COMMENT ON FUNCTION contenu_de IS
    'Range une ligne de planning dans l''une des six familles cochables :
     cours, travail, perso, taches, sport, weekends (NOT-6).';


-- -----------------------------------------------------------------------------
-- 2. Un calendrier composé                                        (NOT-5, NOT-7)
--
-- Le jeton est distinct de celui du compte, et se supprime avec le calendrier :
-- rendre une adresse muette ne doit pas couper les autres abonnements, ni
-- obliger à renouveler le jeton personnel.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS calendrier (
    id_calendrier   SERIAL       PRIMARY KEY,
    jeton           VARCHAR(64)  NOT NULL UNIQUE
                                 DEFAULT replace(gen_random_uuid()::TEXT, '-', ''),
    libelle         VARCHAR(60)  NOT NULL CHECK (length(btrim(libelle)) > 0),
    id_proprietaire INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur)
                                 ON DELETE CASCADE,
    personnes       INTEGER[]    NOT NULL CHECK (cardinality(personnes) > 0),
    contenus        TEXT[]       NOT NULL CHECK (cardinality(contenus) > 0),
    date_creation   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (id_proprietaire, libelle)
);

ALTER TABLE calendrier DROP CONSTRAINT IF EXISTS calendrier_contenus_connus;
ALTER TABLE calendrier ADD CONSTRAINT calendrier_contenus_connus
    CHECK (contenus <@ ARRAY['cours', 'travail', 'perso',
                             'taches', 'sport', 'weekends']::TEXT[]);

COMMENT ON TABLE calendrier IS
    'Calendrier composé : une ou plusieurs personnes, une ou plusieurs familles
     de contenu, un jeton d''abonnement à lui (NOT-5).';

COMMENT ON COLUMN calendrier.personnes IS
    'Les comptes dont le planning entre dans ce flux. Un tableau et non une
     table de liaison : on n''y accède jamais autrement que d''un bloc.';


-- -----------------------------------------------------------------------------
-- 3. Le planning filtré                                           (NOT-6, NOT-8)
--
-- Le nom de la personne accompagne chaque ligne : sans lui, un calendrier à
-- deux afficherait deux cours à la même heure sans dire de qui.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS planning_filtre(INTEGER[], TEXT[], TIMESTAMPTZ, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION planning_filtre(
    p_personnes INTEGER[],
    p_contenus  TEXT[],
    p_debut     TIMESTAMPTZ,
    p_fin       TIMESTAMPTZ)
RETURNS TABLE (
    nature          TEXT,
    id              BIGINT,
    id_utilisateur  INTEGER,
    qui             TEXT,
    contenu         TEXT,
    categorie       TEXT,
    libelle         TEXT,
    debut           TIMESTAMPTZ,
    fin             TIMESTAMPTZ,
    journee_entiere BOOLEAN,
    statut          TEXT,
    lieu            TEXT,
    motif           TEXT,
    nb_relances     INTEGER)
LANGUAGE sql STABLE AS $$
    SELECT p.nature::TEXT, p.id, p.id_utilisateur, u.nom::TEXT,
           contenu_de(p.nature::TEXT, p.categorie::TEXT),
           p.categorie::TEXT, p.libelle::TEXT, p.debut, p.fin,
           p.journee_entiere, p.statut::TEXT, p.lieu::TEXT, p.motif::TEXT,
           p.nb_relances
      FROM v_planning p
      JOIN utilisateur u ON u.id_utilisateur = p.id_utilisateur
     WHERE p.id_utilisateur = ANY (p_personnes)
       AND p.debut < p_fin
       AND p.fin   > p_debut
       AND contenu_de(p.nature::TEXT, p.categorie::TEXT) = ANY (p_contenus)
     ORDER BY p.debut, u.nom;
$$;

COMMENT ON FUNCTION planning_filtre IS
    'Le planning des personnes demandées, réduit aux familles de contenu
     demandées (NOT-6).';


-- -----------------------------------------------------------------------------
-- 4. Créer, lister, supprimer                                     (NOT-5, NOT-7)
--
-- Chacun peut composer le calendrier de l'autre : on vit à deux, et un planning
-- que l'autre ne peut pas consulter oblige à le lui redemander tous les jours.
-- Ce qui reste cloisonné, c'est le reste de l'API : un jeton de calendrier ne
-- donne que la lecture d'un planning, jamais le droit d'y toucher (UTI-2).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION creer_calendrier(
    p_proprietaire INTEGER,
    p_libelle      TEXT,
    p_personnes    INTEGER[],
    p_contenus     TEXT[])
RETURNS calendrier LANGUAGE plpgsql AS $$
DECLARE
    v_inconnu INTEGER;
    v_ligne   calendrier;
BEGIN
    IF p_personnes IS NULL OR cardinality(p_personnes) = 0 THEN
        RAISE EXCEPTION 'Il faut au moins une personne dans un calendrier';
    END IF;

    IF p_contenus IS NULL OR cardinality(p_contenus) = 0 THEN
        RAISE EXCEPTION 'Il faut au moins un contenu dans un calendrier';
    END IF;

    SELECT x INTO v_inconnu
      FROM unnest(p_personnes) x
     WHERE NOT EXISTS (SELECT 1 FROM utilisateur u
                        WHERE u.id_utilisateur = x AND u.actif)
     LIMIT 1;

    IF v_inconnu IS NOT NULL THEN
        RAISE EXCEPTION 'Compte % inconnu ou désactivé', v_inconnu;
    END IF;

    INSERT INTO calendrier (libelle, id_proprietaire, personnes, contenus)
    VALUES (btrim(p_libelle), p_proprietaire,
            -- Trié et dédoublonné : « Thomas et Lorette » et « Lorette et
            -- Thomas » sont le même calendrier, et doivent se ressembler.
            ARRAY(SELECT DISTINCT x FROM unnest(p_personnes) x ORDER BY x),
            ARRAY(SELECT DISTINCT c FROM unnest(p_contenus) c ORDER BY c))
    RETURNING * INTO v_ligne;

    RETURN v_ligne;
END $$;

COMMENT ON FUNCTION creer_calendrier IS
    'Crée un calendrier composé et rend son jeton. Refuse un compte inconnu,
     une liste vide de personnes ou de contenus (NOT-5).';


CREATE OR REPLACE FUNCTION supprimer_calendrier(p_proprietaire INTEGER,
                                                p_calendrier   INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_parti BOOLEAN;
BEGIN
    DELETE FROM calendrier
     WHERE id_calendrier = p_calendrier
       AND id_proprietaire = p_proprietaire
    RETURNING TRUE INTO v_parti;

    RETURN COALESCE(v_parti, FALSE);
END $$;

COMMENT ON FUNCTION supprimer_calendrier IS
    'Supprime un calendrier, et seulement si on en est le propriétaire. Son
     adresse cesse aussitôt de répondre, les autres continuent (NOT-7).';


-- -----------------------------------------------------------------------------
-- 5. Reconnaître un jeton d'abonnement                                  (NOT-8)
--
-- Deux sortes de jetons ouvrent le flux : celui d'un compte, qui donne tout
-- son planning, et celui d'un calendrier composé, qui donne exactement ce qu'on
-- a coché. Une seule fonction les reconnaît, pour que l'URL reste la même.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION abonnement_du_jeton(p_jeton TEXT)
RETURNS TABLE (
    id_calendrier  INTEGER,
    libelle        TEXT,
    id_utilisateur INTEGER,
    pseudo         TEXT,
    role           TEXT,
    personnes      INTEGER[],
    contenus       TEXT[])
LANGUAGE sql STABLE AS $$
    SELECT NULL::INTEGER, 'Planning'::TEXT, u.id_utilisateur, u.pseudo::TEXT,
           u.role::TEXT, ARRAY[u.id_utilisateur],
           ARRAY['cours', 'travail', 'perso', 'taches', 'sport', 'weekends']::TEXT[]
      FROM utilisateur u
     WHERE u.jeton_calendrier = p_jeton AND u.actif

    UNION ALL

    SELECT c.id_calendrier, c.libelle::TEXT, u.id_utilisateur, u.pseudo::TEXT,
           u.role::TEXT, c.personnes, c.contenus
      FROM calendrier c
      JOIN utilisateur u ON u.id_utilisateur = c.id_proprietaire
     WHERE c.jeton = p_jeton AND u.actif;
$$;

COMMENT ON FUNCTION abonnement_du_jeton IS
    'Le jeton d''un compte donne tout son planning ; celui d''un calendrier
     composé donne ce qu''il déclare (NOT-8).';
