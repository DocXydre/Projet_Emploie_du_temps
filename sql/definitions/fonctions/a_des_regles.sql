CREATE OR REPLACE FUNCTION a_des_regles(p_tache INTEGER)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM regle_tache
                    WHERE id_tache = p_tache AND etat = 'active');
$$;

COMMENT ON FUNCTION a_des_regles(INTEGER) IS
    'CND-8 : vrai si la tâche a au moins une règle active, en vigueur ou non.';
