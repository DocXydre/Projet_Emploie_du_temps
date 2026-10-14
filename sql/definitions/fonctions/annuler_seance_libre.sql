-- -----------------------------------------------------------------------------
-- Annuler une séance libre lancée par erreur                          (SAI-19)
--
-- Elle n'a jamais eu lieu : elle disparaît avec ses séries, en cascade. Une
-- séance close (bilan donné, faite, séries figées par la synthèse) ne s'annule
-- plus : elle est déjà dans ce que HAL a lu.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION annuler_seance_libre(p_utilisateur INTEGER, p_occurrence INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM seance se JOIN occurrence o
                       ON o.id_occurrence = se.id_occurrence
                    WHERE se.id_occurrence = p_occurrence
                      AND o.id_utilisateur = p_utilisateur
                      AND se.libre) THEN
        RAISE EXCEPTION 'Séance libre introuvable' USING ERRCODE = 'no_data_found';
    END IF;
    IF EXISTS (SELECT 1 FROM occurrence o
                WHERE o.id_occurrence = p_occurrence
                  AND o.statut NOT IN ('a_placer', 'planifiee', 'notifiee'))
       OR EXISTS (SELECT 1 FROM bilan_seance b WHERE b.id_occurrence = p_occurrence)
       OR EXISTS (SELECT 1 FROM serie_saisie ss
                   WHERE ss.id_occurrence = p_occurrence AND ss.figee) THEN
        RAISE EXCEPTION 'Cette séance est déjà close : elle ne s''annule plus'
              USING ERRCODE = 'check_violation';
    END IF;

    DELETE FROM occurrence o WHERE o.id_occurrence = p_occurrence;
    RETURN p_occurrence;
END $$;

COMMENT ON FUNCTION annuler_seance_libre(INTEGER, INTEGER) IS
    'SAI-19 : une séance libre lancée par erreur disparaît avec ses séries, tant
     qu''elle n''est pas close.';
