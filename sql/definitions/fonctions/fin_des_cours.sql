CREATE OR REPLACE FUNCTION fin_des_cours(p_utilisateur INTEGER, p_jour DATE)
RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT max(LEAST(upper(o.periode), debut_jour(p_jour + 1)))
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.type = 'cours'
       AND o.periode && tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)');
$$;

COMMENT ON FUNCTION fin_des_cours IS
    'Fin du dernier cours de la journée, ou NULL si la journée n''en a aucun.
     Sert d''ancre à la préférence « apres » (SPT-12). Le travail en est exclu :
     un service du soir rendrait l''ancre inatteignable.';
