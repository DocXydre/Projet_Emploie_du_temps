-- -----------------------------------------------------------------------------
-- Une journée sans cours ni travail                                    (TAC-17)
--
-- Le sport, les créneaux personnels et les petites tâches ne comptent pas : une
-- journée où l'on va courir reste une journée où l'on a le temps de faire un
-- coup de ménage en plus.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION journee_libre(p_utilisateur INTEGER, p_jour DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (
        SELECT 1 FROM occupation
         WHERE id_utilisateur = p_utilisateur
           AND type IN ('cours', 'travail')
           AND periode && tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)')
    );
$$;

COMMENT ON FUNCTION journee_libre(INTEGER, DATE) IS
    'TAC-17 : vrai si la personne n''a ni cours ni travail ce jour-là.';
