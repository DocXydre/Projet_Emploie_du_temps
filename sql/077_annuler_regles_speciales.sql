-- =============================================================================
-- 077 : retrait des règles spéciales de la migration 076
--
-- Rejouable.
--
-- La migration 076 (règles par briques, rythme, pénibilité, rappels de HAL) est
-- retirée du dépôt : ce n'était pas ce qui était voulu. Son fichier n'existe
-- plus, mais une base où elle est passée garde ses tables, ses colonnes et ses
-- fonctions. Celle-ci les retire, pour que la base redevienne celle de la
-- migration 075.
--
-- Sur une base où la 076 n'est jamais passée, rien ne se passe : tout est en
-- IF EXISTS.
--
-- Les fonctions d'abord, celles dont la signature avait changé surtout : sans
-- ce retrait, chercher_jour(a, b, c) trouverait deux candidates, l'ancienne et
-- celle à quatre arguments dont le dernier a un défaut, et PostgreSQL
-- refuserait l'appel comme ambigu. Le placement casserait.
--
-- Les colonnes partent avec CASCADE : une vue qui les lisait est retirée avec
-- elles, et sql/definitions/ la recrée juste après.
-- =============================================================================


-- 1. Les fonctions de la 076, et les signatures qu'elle avait changées.
DROP FUNCTION IF EXISTS chercher_jour(INTEGER, TSTZRANGE, INTERVAL, INTEGER);
DROP FUNCTION IF EXISTS chercher_creneau(INTEGER, TSTZRANGE, INTERVAL, TIME, TIME, BOOLEAN, BOOLEAN, INTEGER);
DROP FUNCTION IF EXISTS creer_tache(TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, DATE, DATE,
                                    INTEGER, INTEGER, INTEGER, TIME, TIME, TEXT, INTEGER,
                                    INTEGER, TEXT, TEXT);

DROP VIEW IF EXISTS v_regle_tache;

DROP FUNCTION IF EXISTS a_des_regles(INTEGER);
DROP FUNCTION IF EXISTS brique_tient(TEXT, TEXT, INTEGER, JSONB, INTEGER, DATE);
DROP FUNCTION IF EXISTS brique_tient_pour(TEXT, JSONB, INTEGER, DATE);
DROP FUNCTION IF EXISTS briques_tiennent(JSONB, INTEGER, DATE);
DROP FUNCTION IF EXISTS chercher_place(INTEGER, INTEGER, TSTZRANGE);
DROP FUNCTION IF EXISTS dans_validite(DATERANGE, BOOLEAN, DATE);
DROP FUNCTION IF EXISTS duree_en_clair(INTEGER);
DROP FUNCTION IF EXISTS ecrire_briques(INTEGER, JSONB);
DROP FUNCTION IF EXISTS entretenir_regles();
DROP FUNCTION IF EXISTS fenetre_preferee(TSTZRANGE, TEXT);
DROP FUNCTION IF EXISTS frequence_de(INTEGER, DATE);
DROP FUNCTION IF EXISTS jours_possibles(INTEGER, JSONB, DATERANGE, BOOLEAN, DATE, INTEGER);
DROP FUNCTION IF EXISTS liste_en_clair(TEXT[], TEXT);
DROP FUNCTION IF EXISTS modifier_regle(INTEGER, TEXT, JSONB, TEXT, DATERANGE, BOOLEAN, JSONB);
DROP FUNCTION IF EXISTS motif_brique(TEXT, TEXT, INTEGER, JSONB);
DROP FUNCTION IF EXISTS motif_regle(INTEGER, JSONB, DATERANGE, BOOLEAN, JSONB);
DROP FUNCTION IF EXISTS periode_de(TEXT, DATE);
DROP FUNCTION IF EXISTS phrase_brique(TEXT, TEXT, INTEGER, JSONB);
DROP FUNCTION IF EXISTS poser_regle(INTEGER, INTEGER, JSONB, TEXT, DATERANGE, BOOLEAN, JSONB, BIGINT);
DROP FUNCTION IF EXISTS regles_tiennent(INTEGER, INTEGER, DATE);
DROP FUNCTION IF EXISTS remplir_periode(INTEGER, INTEGER, DATERANGE);
DROP FUNCTION IF EXISTS retirer_regle(INTEGER);
DROP FUNCTION IF EXISTS traduire_regle(JSONB, DATERANGE, BOOLEAN, JSONB);

-- Les déclencheurs sur tache, avant leurs fonctions.
DROP TRIGGER IF EXISTS tache_rythme ON tache;
DROP FUNCTION IF EXISTS trg_tache_rythme();


-- 2. Les tables. Leurs déclencheurs partent avec elles, puis la fonction du
--    déclencheur des briques, qui en dépendait.
ALTER TABLE occurrence DROP COLUMN IF EXISTS id_regle_tache CASCADE;
DROP TABLE IF EXISTS rappel_hal;
DROP TABLE IF EXISTS brique_regle;
DROP TABLE IF EXISTS regle_tache;
DROP FUNCTION IF EXISTS trg_brique_regle_verifier();


-- 3. Les colonnes du rythme et de la pénibilité.
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_rythme;
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_rythme_moment;
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_penibilite;
ALTER TABLE tache
    DROP COLUMN IF EXISTS rythme_nombre CASCADE,
    DROP COLUMN IF EXISTS rythme_periode CASCADE,
    DROP COLUMN IF EXISTS rythme_moment CASCADE,
    DROP COLUMN IF EXISTS penibilite CASCADE;

ALTER TABLE type_tache DROP CONSTRAINT IF EXISTS type_tache_penibilite;
ALTER TABLE type_tache DROP COLUMN IF EXISTS penibilite CASCADE;


-- 4. Le type de notification « regle » : celles qui l'ont, puis la liste
--    d'avant (072).
DELETE FROM notification WHERE type = 'regle';
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_type_check;
ALTER TABLE notification ADD CONSTRAINT notification_type_check
    CHECK (type IN ('rappel', 'bilan', 'alerte', 'sport', 'coach', 'changement',
                    'administration', 'demande'));
