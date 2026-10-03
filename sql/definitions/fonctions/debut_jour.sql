-- -----------------------------------------------------------------------------
-- Bornes d'une journée civile française, en UTC
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION debut_jour(p_jour DATE)
RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT (p_jour::TIMESTAMP) AT TIME ZONE 'Europe/Paris';
$$;
