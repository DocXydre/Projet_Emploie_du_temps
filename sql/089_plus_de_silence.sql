-- =============================================================================
-- 089 : plus d'heures de silence                                (NOT-15, lot C)
--
-- Rejouable. Tout est en IF EXISTS : rejouée, elle ne retire rien de plus.
-- =============================================================================

-- Les fonctions d'abord. regler_heures change de signature (plus de silence_debut ni
-- silence_fin) : PostgreSQL ne remplace pas une fonction dont les arguments changent, il
-- en garderait deux et l'appel à quatre arguments deviendrait ambigu. en_silence n'a plus
-- de fichier dans sql/definitions/ : le chargement ne retire que ce qu'il recrée.
DROP FUNCTION IF EXISTS regler_heures(INTEGER, TIME, TIME, TIME, TIME, TIME);
DROP FUNCTION IF EXISTS en_silence(INTEGER, TIMESTAMPTZ);

-- Puis la contrainte et les colonnes (ajoutées par la 061). La contrainte est citée
-- explicitement : sql/appliquer.sh s'en sert pour refuser de rejouer la 061, dont la
-- 089 reprend une partie.
ALTER TABLE utilisateur DROP CONSTRAINT IF EXISTS utilisateur_silence_non_vide;
ALTER TABLE utilisateur
    DROP COLUMN IF EXISTS silence_debut CASCADE,
    DROP COLUMN IF EXISTS silence_fin CASCADE;
