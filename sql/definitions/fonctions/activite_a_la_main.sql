-- -----------------------------------------------------------------------------
-- Une séance déclarée à la main ?                                      (MON-12)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION activite_a_la_main(p_details JSONB)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE((p_details ->> 'saisie_manuelle')::BOOLEAN, FALSE)
$$;

COMMENT ON FUNCTION activite_a_la_main(JSONB) IS
    'MON-12 : vrai pour une course ou du cardio déclarés à la main, sans rien
     qui les enregistre.';
