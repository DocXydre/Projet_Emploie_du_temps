-- -----------------------------------------------------------------------------
-- Oublier un trajet                                                    (TRJ-11)
--
-- Annuler doit tout retirer : l'absence, et les trains posés au planning.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION oublier_trajet(p_absence INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    t       RECORD;
    v_n     INTEGER := 0;
BEGIN
    FOR t IN SELECT id_trajet FROM trajet WHERE id_absence = p_absence LOOP
        v_n := v_n + COALESCE(retirer_trajet_du_planning(t.id_trajet), 0);
    END LOOP;

    UPDATE trajet SET statut = 'ecartee', id_absence = NULL
     WHERE id_absence = p_absence;

    DELETE FROM absence WHERE id_absence = p_absence;
    RETURN v_n;
END $$;

COMMENT ON FUNCTION oublier_trajet IS
    'Annule une absence issue d''un billet : l''absence part, et les trains
     quittent le planning avec elle (TRJ-11).';
