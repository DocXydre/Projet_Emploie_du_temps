CREATE OR REPLACE FUNCTION appartement_vide(p_jour DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT cardinality(presents_le(p_jour)) = 0;
$$;
