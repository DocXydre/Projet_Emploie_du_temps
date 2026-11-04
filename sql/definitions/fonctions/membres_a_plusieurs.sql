-- -----------------------------------------------------------------------------
-- Une tâche se fait-elle à plusieurs ?                                  (RGL-7)
--
-- Le nombre de membres que demande la règle a_plusieurs en vigueur de la tâche,
-- NULL si elle n'en a pas (jamais posée, retirée, remplacée par une autre).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION membres_a_plusieurs(p_tache INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT (r.parametres ->> 'membres')::INTEGER
      FROM regle r
     WHERE r.id_tache = p_tache
       AND r.sorte = 'a_plusieurs'
       AND r.etat = 'active'
     ORDER BY r.id_regle DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION membres_a_plusieurs IS
    'RGL-7 : le nombre de membres de la règle a_plusieurs en vigueur d''une tâche, NULL si elle n''en a pas. Une tâche est à plusieurs quand le résultat n''est pas NULL.';
