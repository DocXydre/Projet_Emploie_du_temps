-- -----------------------------------------------------------------------------
-- Présence dans l'appartement                                     (ABS-1, ABS-2)
--
-- Un jour n'est absent que s'il est entièrement couvert par une absence.
-- Partir vendredi soir laisse donc la journée de vendredi utilisable : la
-- tâche peut encore être faite avant le départ.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION est_absent(p_utilisateur INTEGER, p_jour DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM absence
         WHERE id_utilisateur = p_utilisateur
           AND periode @> tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)')
    );
$$;
