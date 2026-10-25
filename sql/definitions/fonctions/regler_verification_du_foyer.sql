-- -----------------------------------------------------------------------------
-- Le jour et l'heure de la vérification de la semaine                   (VER-8)
--
-- L'administrateur du foyer les règle ; le lundi à 6h30 par défaut. Changer le
-- jour ne refait pas la vérification de cette semaine si elle a déjà eu lieu.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION regler_verification_du_foyer(p_admin INTEGER, p_jour INTEGER,
                                                        p_heure TIME)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_foyer INTEGER := exiger_admin_du_foyer(p_admin);
BEGIN
    IF p_jour IS NOT NULL AND p_jour NOT BETWEEN 1 AND 7 THEN
        RAISE EXCEPTION 'Le jour va de 1, lundi, à 7, dimanche' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE foyer
       SET verification_jour  = COALESCE(p_jour, verification_jour),
           verification_heure = COALESCE(p_heure, verification_heure)
     WHERE id_foyer = v_foyer;
END $$;

COMMENT ON FUNCTION regler_verification_du_foyer(INTEGER, INTEGER, TIME) IS
    'VER-8 : l''administrateur du foyer règle le jour et l''heure de la vérification de la semaine.';
