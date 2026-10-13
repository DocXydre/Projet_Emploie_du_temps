-- -----------------------------------------------------------------------------
-- Retirer un membre                                                      (FOY-5)
--
-- Un geste de l'administrateur du foyer, qui ne se retire pas lui-même : il
-- passe son rôle ou quitte le foyer.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retirer_du_foyer(p_admin INTEGER, p_membre INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_foyer INTEGER := exiger_admin_du_foyer(p_admin);
BEGIN
    IF p_membre = p_admin THEN
        RAISE EXCEPTION 'Pour partir toi-même, quitte le foyer après avoir passé ton rôle'
              USING ERRCODE = 'check_violation';
    END IF;
    IF foyer_de(p_membre) IS DISTINCT FROM v_foyer THEN
        RAISE EXCEPTION 'Ce compte ne fait pas partie de ton foyer' USING ERRCODE = 'no_data_found';
    END IF;
    PERFORM sortir_du_foyer(p_membre);
END $$;

COMMENT ON FUNCTION retirer_du_foyer(INTEGER, INTEGER) IS
    'FOY-5 : l''administrateur retire un membre de son foyer.';
