-- Le bloc à réserver : marge, trajet, séance, trajet, marge (SPT-10).
CREATE OR REPLACE FUNCTION bloc_de_seance(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ
) RETURNS TSTZRANGE LANGUAGE sql STABLE AS $$
    SELECT tstzrange(p_debut - x.trajet - x.marge,
                     p_debut + duree_seance(p_lieu) + x.trajet + x.marge, '[)')
      FROM (SELECT make_interval(mins => trajet_minutes(p_utilisateur,
                                                        jour_de(p_debut), l.id_lieu)) AS trajet,
                   make_interval(mins => l.marge_minutes) AS marge
              FROM lieu_sport l
             WHERE l.id_lieu = p_lieu) x;
$$;
