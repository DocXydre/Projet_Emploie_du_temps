-- =============================================================================
-- 065 : le retrait de l'ancien sport, pour tous         (B.10.3, annexe 2)
--
-- Rejouable.
--
-- Chaque membre a HAL : il propose les séances, sur quatre semaines (SPT-33).
-- Les réservations « à déterminer », le minimum hebdomadaire, les habitudes,
-- les propositions du moteur et l'alerte du lundi s'en vont. Les fonctions de
-- séance ne font plus qu'une : obstacle_seance() et bloc_de_seance() portent
-- la durée et la discipline de la séance.
--
-- Rien du passé ne se perd : les séances choisies, faites ou pas faites,
-- restent ; les choix et les minimums partent dans le schéma « archive ».
-- Le code retiré est dans anciennes_fonctionnalites/reservations_sport/.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Les fonctions retirées
--
-- Toutes leurs signatures, telles qu'elles sont en base. Les deux fonctions
-- fusionnées perdent leur ancienne signature : la nouvelle arrive avec les
-- définitions, juste après.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    f REGPROCEDURE;
BEGIN
    FOR f IN
        SELECT p.oid::REGPROCEDURE
          FROM pg_proc p
         WHERE p.pronamespace = 'public'::REGNAMESPACE
           AND p.proname IN ('organiser_sport', 'organiser_sport_semaine',
                             'propositions_sport', 'habitudes_sport',
                             'regler_minimum_sport', 'minimum_sport',
                             'alerte_sport_du_lundi', 'seances_a_determiner_passees',
                             'heures_seance_sport', 'meilleure_heure_sport',
                             'heures_candidates', 'sportifs',
                             'obstacle_seance_coach', 'bloc_seance_duree', 'duree_seance')
    LOOP
        EXECUTE format('DROP FUNCTION %s', f);
    END LOOP;
END $$;

DROP FUNCTION IF EXISTS obstacle_seance(INTEGER, INTEGER, TIMESTAMPTZ, INTEGER, BOOLEAN);
DROP FUNCTION IF EXISTS bloc_de_seance(INTEGER, INTEGER, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS choisir_seance_sport(INTEGER, INTEGER, TIMESTAMPTZ, INTEGER, VARCHAR);


-- -----------------------------------------------------------------------------
-- 2. Les réservations « à déterminer » encore ouvertes
--
-- Celles qui sont closes (passées sans être choisies) restent : elles disent
-- l'histoire, et les vues les écartent déjà.
-- -----------------------------------------------------------------------------
DELETE FROM occurrence
 WHERE origine = 'quota'
   AND statut IN ('a_placer', 'planifiee', 'notifiee');


-- -----------------------------------------------------------------------------
-- 3. Les habitudes et le minimum partent en archive                (SPT-22, SPT-28)
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS archive;

ALTER TABLE IF EXISTS choix_sport SET SCHEMA archive;
ALTER TABLE IF EXISTS archive.choix_sport
    DROP CONSTRAINT IF EXISTS choix_sport_id_occurrence_fkey;
ALTER TABLE IF EXISTS archive.choix_sport
    DROP CONSTRAINT IF EXISTS choix_sport_id_lieu_fkey;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'utilisateur'
                  AND column_name = 'minimum_sport') THEN
        CREATE TABLE IF NOT EXISTS archive.minimum_sport (
            id_utilisateur INTEGER  PRIMARY KEY,
            minimum_sport  SMALLINT NOT NULL
        );
        INSERT INTO archive.minimum_sport (id_utilisateur, minimum_sport)
        SELECT id_utilisateur, minimum_sport FROM utilisateur
         WHERE minimum_sport IS NOT NULL
        ON CONFLICT (id_utilisateur) DO NOTHING;
        ALTER TABLE utilisateur DROP COLUMN minimum_sport;
    END IF;
END $$;

COMMENT ON SCHEMA archive IS
    'Données des fonctionnalités retirées. Hors du chemin de recherche : rien
     dans l''application ne les lit. Voir anciennes_fonctionnalites/.';
