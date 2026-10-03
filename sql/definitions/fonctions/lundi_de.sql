-- -----------------------------------------------------------------------------
-- Semaine ISO
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lundi_de(p_jour DATE) RETURNS DATE
LANGUAGE sql IMMUTABLE AS $$
    SELECT p_jour - (EXTRACT(ISODOW FROM p_jour)::INTEGER - 1);
$$;
