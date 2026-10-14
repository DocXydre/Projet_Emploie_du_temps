CREATE OR REPLACE FUNCTION heures_seance_sport(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_jour        DATE,
    p_ignorer     INTEGER DEFAULT NULL
) RETURNS SETOF TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT h FROM heures_candidates(p_lieu, p_jour) h
     WHERE obstacle_seance(p_utilisateur, p_lieu, h, p_ignorer, TRUE) IS NULL
     ORDER BY h;
$$;
