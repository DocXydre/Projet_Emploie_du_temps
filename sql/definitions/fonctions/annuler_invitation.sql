-- -----------------------------------------------------------------------------
-- Annuler une invitation pas encore servie                               (FOY-3)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION annuler_invitation(p_admin INTEGER, p_invitation INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_foyer INTEGER := exiger_admin_du_foyer(p_admin);
BEGIN
    UPDATE invitation SET annulee_le = now()
     WHERE id_invitation = p_invitation AND id_foyer = v_foyer
       AND servie_le IS NULL AND annulee_le IS NULL;
    RETURN FOUND;
END $$;

COMMENT ON FUNCTION annuler_invitation(INTEGER, INTEGER) IS
    'FOY-3 : annule une invitation de son foyer qui n''a pas encore servi.';
