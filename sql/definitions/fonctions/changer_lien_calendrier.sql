-- -----------------------------------------------------------------------------
-- Donner ou changer le lien d'un calendrier suivi               (COL-7, COL-14)
--
-- Le pendant de « /lien » : un calendrier personnel né sans adresse s'allume,
-- un flux arrêté reprend, un lien renouvelé remplace l'ancien. Donner le lien
-- vaut demande de collecte : l'API la lance ensuite.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION changer_lien_calendrier(p_auteur    INTEGER,
                                                   p_id_source INTEGER,
                                                   p_url       TEXT)
RETURNS VARCHAR LANGUAGE plpgsql AS $$
DECLARE
    v_code VARCHAR := calendrier_du_foyer(p_auteur, p_id_source);
BEGIN
    IF p_url IS NULL OR p_url !~* '^https?://[^/\s]+' THEN
        RAISE EXCEPTION 'Le lien doit commencer par https://' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE source SET url = p_url, active = TRUE, etat = 'ok' WHERE id_source = p_id_source;
    RETURN v_code;
END $$;

COMMENT ON FUNCTION changer_lien_calendrier(INTEGER, INTEGER, TEXT) IS
    'COL-7 : donne ou remplace le lien d''un calendrier du foyer, et le rallume.';
