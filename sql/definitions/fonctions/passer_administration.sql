-- -----------------------------------------------------------------------------
-- Passer son rôle d'administrateur                                       (FOY-7)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION passer_administration(p_admin INTEGER, p_membre INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_foyer INTEGER := exiger_admin_du_foyer(p_admin);
BEGIN
    IF p_membre = p_admin THEN
        RAISE EXCEPTION 'Tu es déjà l''administrateur' USING ERRCODE = 'check_violation';
    END IF;
    IF foyer_de(p_membre) IS DISTINCT FROM v_foyer THEN
        RAISE EXCEPTION 'Ce compte ne fait pas partie de ton foyer' USING ERRCODE = 'no_data_found';
    END IF;
    UPDATE foyer SET id_administrateur = p_membre WHERE id_foyer = v_foyer;
END $$;

COMMENT ON FUNCTION passer_administration(INTEGER, INTEGER) IS
    'FOY-7 : l''administrateur du foyer donne son rôle à un autre membre.';
