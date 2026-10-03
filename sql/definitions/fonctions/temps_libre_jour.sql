CREATE OR REPLACE FUNCTION temps_libre_jour(p_utilisateur INTEGER, p_jour DATE)
RETURNS INTERVAL LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(upper(d) - lower(d)), INTERVAL '0')
      FROM disponibilites(p_utilisateur, debut_jour(p_jour), debut_jour(p_jour + 1)) d;
$$;
