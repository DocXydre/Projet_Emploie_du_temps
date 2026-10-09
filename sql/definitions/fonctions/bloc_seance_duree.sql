CREATE OR REPLACE FUNCTION bloc_seance_duree(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ,
    p_duree       INTEGER
) RETURNS TSTZRANGE LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_lieu IS NULL
                THEN tstzrange(p_debut, p_debut + make_interval(mins => p_duree), '[)')
                ELSE (SELECT tstzrange(p_debut - x.trajet - x.marge,
                                       p_debut + make_interval(mins => p_duree)
                                               + x.trajet + x.marge, '[)')
                        FROM (SELECT make_interval(mins => trajet_minutes(
                                         p_utilisateur, jour_de(p_debut), l.id_lieu)) AS trajet,
                                     make_interval(mins => l.marge_minutes) AS marge
                                FROM lieu_sport l
                               WHERE l.id_lieu = p_lieu) x)
           END;
$$;

COMMENT ON FUNCTION bloc_seance_duree(INTEGER, INTEGER, TIMESTAMPTZ, INTEGER) IS
    'SPT-34 : le bloc d''une séance qui porte sa propre durée, trajet et
     battement du lieu compris (SPT-4, SPT-10).';
