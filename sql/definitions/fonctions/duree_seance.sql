CREATE OR REPLACE FUNCTION duree_seance(p_lieu INTEGER) RETURNS INTERVAL
LANGUAGE sql STABLE AS $$
    SELECT make_interval(mins => COALESCE(l.duree_minutes, t.duree_minutes))
      FROM lieu_sport l, tache t
     WHERE l.id_lieu = p_lieu AND t.code = 'SPORT';
$$;
