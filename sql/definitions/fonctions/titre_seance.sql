CREATE OR REPLACE FUNCTION titre_seance(p_discipline VARCHAR, p_etat VARCHAR, p_libre BOOLEAN)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_discipline WHEN 'musculation' THEN 'Musculation'
                             WHEN 'course'      THEN 'Course à pied'
                             ELSE 'Cardio' END
           || CASE WHEN p_libre THEN ' libre'
                   WHEN p_etat = 'proposee' THEN ' (à valider)'
                   ELSE '' END;
$$;

COMMENT ON FUNCTION titre_seance(VARCHAR, VARCHAR, BOOLEAN) IS
    'NOT-13 : le titre d''une séance au planning et dans le flux iCalendar. Une
     séance proposée s''y lit « à valider ». Son contenu n''y figure jamais.';
