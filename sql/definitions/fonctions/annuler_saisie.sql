-- -----------------------------------------------------------------------------
-- Retirer les séries d'un lancement annulé                            (SAI-19)
--
-- Une séance prévue lancée puis annulée reste à faire. Seules les séries que
-- l'appareil a envoyées pendant ce lancement s'en vont, désignées par leur
-- clé. Une série figée ne bouge pas (SAI-8).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION annuler_saisie(p_utilisateur INTEGER, p_occurrence INTEGER,
                                          p_cles UUID[])
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_retirees INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM occurrence o
                    WHERE o.id_occurrence = p_occurrence
                      AND o.id_utilisateur = p_utilisateur) THEN
        RAISE EXCEPTION 'Séance introuvable' USING ERRCODE = 'no_data_found';
    END IF;

    DELETE FROM serie_saisie ss
     WHERE ss.id_occurrence = p_occurrence AND NOT ss.figee
       AND ss.cle_client = ANY (p_cles);
    GET DIAGNOSTICS v_retirees = ROW_COUNT;
    RETURN v_retirees;
END $$;

COMMENT ON FUNCTION annuler_saisie(INTEGER, INTEGER, UUID[]) IS
    'SAI-19 : retire les séries non figées d''un lancement annulé, désignées par
     la clé que l''appareil leur a donnée.';
