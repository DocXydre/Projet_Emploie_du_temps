CREATE OR REPLACE FUNCTION presents_le(p_jour DATE)
RETURNS INTEGER[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(id_utilisateur ORDER BY id_utilisateur), ARRAY[]::INTEGER[])
      FROM utilisateur
     WHERE actif AND NOT est_absent(id_utilisateur, p_jour);
$$;
