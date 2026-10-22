-- -----------------------------------------------------------------------------
-- Retirer une règle                                            (CND-14, RAP-6)
--
-- Elle reste dans l'historique de la tâche ; ses rappels en attente tombent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retirer_regle(p_regle INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    UPDATE regle_tache SET etat = 'retiree'
     WHERE id_regle_tache = p_regle AND etat IN ('active', 'suspendue');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cette règle n''existe pas, ou elle n''est plus en vigueur'
              USING ERRCODE = 'no_data_found';
    END IF;
    UPDATE rappel_hal SET etat = 'annule'
     WHERE id_regle_tache = p_regle AND etat = 'attente';
END $$;

COMMENT ON FUNCTION retirer_regle(INTEGER) IS
    'CND-14, RAP-6 : retire une règle, garde son historique, annule ses rappels en attente.';
