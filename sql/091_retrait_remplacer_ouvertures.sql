-- =============================================================================
-- 091 : le relevé des horaires du SUAPS est écarté, première partie  (lot H, M30)
--
-- Rejouable. DROP ... IF EXISTS : rien ne casse si la fonction est déjà retirée.
-- =============================================================================

DROP FUNCTION IF EXISTS remplacer_ouvertures(VARCHAR, JSONB);
