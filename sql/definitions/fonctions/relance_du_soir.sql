-- -----------------------------------------------------------------------------
-- La relance du soir de tous les comptes, d'un coup                    (SPT-25)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION relance_du_soir() RETURNS INTEGER
LANGUAGE sql AS $$
    SELECT relance_du_soir_de(NULL)
$$;

COMMENT ON FUNCTION relance_du_soir() IS
    'La relance du soir de tous les comptes. L''ordonnanceur sert chacun à son heure (NOT-15).';
