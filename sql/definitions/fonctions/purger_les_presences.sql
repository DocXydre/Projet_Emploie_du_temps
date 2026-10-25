-- -----------------------------------------------------------------------------
-- Ce qui ne se garde pas                                         (POS-4, MTO-1)
--
-- Les présences finies depuis plus de 90 jours, les questions de plus de 90
-- jours, les prévisions de plus de 48 heures. À 0h05, avec le report d'office.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION purger_les_presences() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_a INTEGER;
    v_b INTEGER;
    v_c INTEGER;
BEGIN
    DELETE FROM presence
     WHERE NOT upper_inf(periode) AND upper(periode) < now() - INTERVAL '90 days';
    GET DIAGNOSTICS v_a = ROW_COUNT;
    DELETE FROM question_presence WHERE posee_le < now() - INTERVAL '90 days';
    GET DIAGNOSTICS v_b = ROW_COUNT;
    DELETE FROM meteo_heure WHERE heure < now() - INTERVAL '48 hours';
    GET DIAGNOSTICS v_c = ROW_COUNT;
    RETURN v_a + v_b + v_c;
END $$;

COMMENT ON FUNCTION purger_les_presences() IS
    'POS-4, MTO-1 : efface les présences et questions de plus de 90 jours, les prévisions de plus de 48 heures.';
