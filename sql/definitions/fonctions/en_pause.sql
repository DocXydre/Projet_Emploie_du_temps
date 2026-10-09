CREATE OR REPLACE FUNCTION en_pause(p_utilisateur INTEGER, p_jour DATE DEFAULT NULL)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM pause p
                    WHERE p.id_utilisateur = p_utilisateur
                      AND p.periode @> COALESCE(p_jour, jour_de(now())));
$$;

COMMENT ON FUNCTION en_pause(INTEGER, DATE) IS
    'PAU-2 : le coach de ce compte est-il en pause ce jour-là ? Aujourd''hui par défaut.';
