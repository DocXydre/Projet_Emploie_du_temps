-- -----------------------------------------------------------------------------
-- Un doublon passe la main à la séance qui compte                      (SAN-15)
--
-- Le perdant pointe vers le gagnant, comme les doublons qui pointaient vers
-- lui, et lâche sa séance. Le gagnant qui n'en avait pas la prend, et
-- l'intensité de la séance se recalcule sur ses données. S'il en avait déjà
-- une, celle du perdant, née du doublon, se retire quand rien n'y a été saisi.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transmettre_activite(p_perdant BIGINT, p_gagnant BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_seance_perdant INTEGER;
    v_seance_gagnant INTEGER;
BEGIN
    SELECT id_occurrence INTO v_seance_perdant FROM activite_sante WHERE id_activite = p_perdant;
    SELECT id_occurrence INTO v_seance_gagnant FROM activite_sante WHERE id_activite = p_gagnant;

    UPDATE activite_sante SET doublon_de = p_gagnant, id_occurrence = NULL
     WHERE id_activite = p_perdant;
    UPDATE activite_sante SET doublon_de = p_gagnant WHERE doublon_de = p_perdant;
    UPDATE activite_sante SET doublon_de = NULL WHERE id_activite = p_gagnant;

    IF v_seance_perdant IS NULL THEN
        RETURN;
    END IF;
    IF v_seance_gagnant IS NULL THEN
        UPDATE activite_sante SET id_occurrence = v_seance_perdant
         WHERE id_activite = p_gagnant;
        IF EXISTS (SELECT 1 FROM seance WHERE id_occurrence = v_seance_perdant) THEN
            PERFORM deduire_intensite(v_seance_perdant);
        END IF;
    ELSE
        PERFORM retirer_seance_reconnue(v_seance_perdant);
    END IF;
END $$;

COMMENT ON FUNCTION transmettre_activite(BIGINT, BIGINT) IS
    'SAN-15 : fait d''une séance de la montre le doublon d''une autre. Sa séance
     prévue passe à la gagnante, ou se retire si elle est née du doublon.';
