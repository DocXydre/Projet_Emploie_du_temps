-- -----------------------------------------------------------------------------
-- Refuser un geste réservé à l'administrateur du foyer                  (FOY-2)
--
-- Rend le foyer de l'appelant s'il en est l'administrateur, et refuse sinon.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION exiger_admin_du_foyer(p_utilisateur INTEGER)
RETURNS INTEGER LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_foyer INTEGER := foyer_de(p_utilisateur);
BEGIN
    IF v_foyer IS NULL THEN
        RAISE EXCEPTION 'Tu ne fais partie d''aucun foyer' USING ERRCODE = 'no_data_found';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM foyer
                    WHERE id_foyer = v_foyer AND id_administrateur = p_utilisateur) THEN
        RAISE EXCEPTION 'Réservé à l''administrateur du foyer'
              USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_foyer;
END $$;

COMMENT ON FUNCTION exiger_admin_du_foyer(INTEGER) IS
    'FOY-2 : le foyer de l''appelant s''il l''administre ; refus sinon.';
