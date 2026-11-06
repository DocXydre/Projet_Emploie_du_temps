-- =============================================================================
-- 092 : le relevé des horaires du SUAPS est écarté, seconde partie   (lot H, M30)
--
-- Rejouable. DROP ... IF EXISTS : rien ne casse si les objets sont déjà retirés.
-- =============================================================================

-- La vue d'abord : elle lit les trois colonnes.
DROP VIEW IF EXISTS v_lieu_a_relever;

ALTER TABLE lieu_sport DROP COLUMN IF EXISTS url_horaires;
ALTER TABLE lieu_sport DROP COLUMN IF EXISTS configuration;
ALTER TABLE lieu_sport DROP COLUMN IF EXISTS horaires_releves_le;
