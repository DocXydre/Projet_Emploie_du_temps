CREATE OR REPLACE FUNCTION regler_minimum_sport(p_utilisateur INTEGER,
                                                p_minimum     INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    IF p_minimum IS NULL OR p_minimum < 0 OR p_minimum > 7 THEN
        RAISE EXCEPTION 'Une fréquence se règle entre 0 et 7 séances par semaine'
              USING ERRCODE = 'check_violation';
    END IF;

    UPDATE utilisateur SET minimum_sport = p_minimum
     WHERE id_utilisateur = p_utilisateur AND actif;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compte % inconnu ou désactivé', p_utilisateur
              USING ERRCODE = 'no_data_found';
    END IF;

    -- Les semaines suivent aussitôt : baisser sa fréquence libère des
    -- réservations, la monter en pose de nouvelles.
    PERFORM organiser_sport(p_utilisateur);
    RETURN minimum_sport(p_utilisateur);
END $$;

COMMENT ON FUNCTION regler_minimum_sport IS
    'Change la fréquence de sport d''un compte et réorganise ses trois
     semaines dans la foulée (SPT-28).';
