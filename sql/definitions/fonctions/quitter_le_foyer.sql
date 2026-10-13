-- -----------------------------------------------------------------------------
-- Quitter son foyer                                                      (FOY-7)
--
-- L'administrateur ne part qu'après avoir passé son rôle, sauf s'il est seul :
-- un foyer ne reste pas sans administrateur.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION quitter_le_foyer(p_membre INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_foyer INTEGER := foyer_de(p_membre);
BEGIN
    IF v_foyer IS NOT NULL
       AND EXISTS (SELECT 1 FROM foyer WHERE id_foyer = v_foyer AND id_administrateur = p_membre)
       AND EXISTS (SELECT 1 FROM utilisateur
                    WHERE id_foyer = v_foyer AND actif AND id_utilisateur <> p_membre) THEN
        RAISE EXCEPTION 'Passe d''abord ton rôle d''administrateur à un autre membre'
              USING ERRCODE = 'check_violation';
    END IF;
    PERFORM sortir_du_foyer(p_membre);
END $$;

COMMENT ON FUNCTION quitter_le_foyer(INTEGER) IS
    'FOY-7 : le membre quitte son foyer ; l''administrateur passe d''abord son rôle.';
