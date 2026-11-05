-- =============================================================================
-- 089 : « Voir plus tard » sur un conflit                              (COL-23)
--
-- Rejouable. La colonne se crée si elle manque, la contrainte se repose.
-- =============================================================================

ALTER TABLE conflit ADD COLUMN IF NOT EXISTS cache_jusqu_a TIMESTAMPTZ;

-- COL-23 : un conflit caché revient sept jours avant sa date au plus tard.
-- La date d'un conflit est le début de sa période : lower(periode).
ALTER TABLE conflit DROP CONSTRAINT IF EXISTS conflit_cache_avant_sept_jours;
ALTER TABLE conflit ADD CONSTRAINT conflit_cache_avant_sept_jours
    CHECK (cache_jusqu_a IS NULL OR cache_jusqu_a <= lower(periode) - INTERVAL '7 days');

COMMENT ON COLUMN conflit.cache_jusqu_a IS
    'COL-23 : « Voir plus tard ». Le conflit ne se montre pas avant cette date, au plus tard sept jours avant son début. Une fois la date passée, il ne se cache plus.';
