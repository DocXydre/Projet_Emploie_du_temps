-- -----------------------------------------------------------------------------
-- Les habitudes                                                        (SPT-22)
--
-- Un même sport, le même jour de la semaine, à la même heure. Son pourcentage
-- est la part des semaines où il a été choisi, sur les huit dernières : ce
-- qu'on fait souvent monte, ce qu'on a cessé de faire s'efface de lui-même.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION habitudes_sport(
    p_utilisateur INTEGER,
    p_reference   DATE DEFAULT NULL
) RETURNS TABLE (
    h_lieu        INTEGER,
    h_jour        SMALLINT,
    h_heure       TIME,
    h_semaines    INTEGER,
    h_total       INTEGER,
    h_pourcentage INTEGER
) LANGUAGE sql STABLE AS $$
    WITH fenetre AS (
        SELECT c.id_lieu, c.jour_semaine, c.heure, c.semaine
          FROM choix_sport c
         WHERE c.id_utilisateur = p_utilisateur
           AND c.semaine >= lundi_de(COALESCE(p_reference, jour_de(now()))) - 56
    ),
    total AS (SELECT count(DISTINCT f.semaine) AS n FROM fenetre f)
    SELECT f.id_lieu, f.jour_semaine, f.heure,
           count(DISTINCT f.semaine)::INTEGER,
           t.n::INTEGER,
           (100 * count(DISTINCT f.semaine) / t.n)::INTEGER
      FROM fenetre f, total t
     WHERE t.n > 0
     GROUP BY f.id_lieu, f.jour_semaine, f.heure, t.n;
$$;
