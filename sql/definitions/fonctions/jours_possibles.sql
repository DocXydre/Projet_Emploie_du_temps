-- -----------------------------------------------------------------------------
-- Les jours où une tâche pourrait se faire                      (CND-8, ACC-17)
--
-- Selon ses règles actives, et, si on en donne, des briques qu'on essaie avant
-- de les poser. Pour celui à qui la tâche revient s'il est fixe ; sinon, un
-- jour compte si l'un des membres le pourrait. Rien n'est écrit.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION jours_possibles(p_tache        INTEGER,
                                           p_briques      JSONB     DEFAULT NULL,
                                           p_validite     DATERANGE DEFAULT NULL,
                                           p_chaque_annee BOOLEAN   DEFAULT FALSE,
                                           p_depuis       DATE      DEFAULT NULL,
                                           p_jours        INTEGER   DEFAULT 56)
RETURNS SETOF DATE LANGUAGE sql STABLE AS $$
    SELECT j::DATE
      FROM tache t,
           generate_series(COALESCE(p_depuis, jour_de(now())),
                           COALESCE(p_depuis, jour_de(now())) + LEAST(GREATEST(p_jours, 1), 366) - 1,
                           INTERVAL '1 day') AS j
     WHERE t.id_tache = p_tache
       AND regles_tiennent(t.id_tache, t.id_utilisateur_defaut, j::DATE)
       AND (p_briques IS NULL
            OR NOT dans_validite(p_validite, COALESCE(p_chaque_annee, FALSE), j::DATE)
            OR briques_tiennent(p_briques, t.id_utilisateur_defaut, j::DATE))
     ORDER BY j;
$$;

COMMENT ON FUNCTION jours_possibles(INTEGER, JSONB, DATERANGE, BOOLEAN, DATE, INTEGER) IS
    'CND-8 : les jours où les règles de la tâche, et les briques essayées, tiendraient. Huit semaines par défaut.';
