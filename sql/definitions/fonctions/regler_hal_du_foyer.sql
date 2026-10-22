-- HDF-1 : l'administrateur du foyer active ou arrête le HAL du foyer.
CREATE OR REPLACE FUNCTION regler_hal_du_foyer(p_admin INTEGER, p_actif BOOLEAN)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_foyer INTEGER := exiger_admin_du_foyer(p_admin);
BEGIN
    UPDATE foyer SET hal_actif = p_actif WHERE id_foyer = v_foyer;
END $$;

COMMENT ON FUNCTION regler_hal_du_foyer(INTEGER, BOOLEAN) IS
    'HDF-1 : l''administrateur du foyer active ou arrête le HAL du foyer.';
