-- -----------------------------------------------------------------------------
-- Fenêtre d'échéance d'une occurrence
--
-- Pour un rappel, la fenêtre est alignée sur des journées entières : c'est ce
-- qui permet ensuite au créneau « journée entière » d'y être inclus (TAC-5).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fenetre_pour(
    p_rappel_journee BOOLEAN,
    p_debut          TIMESTAMPTZ,
    p_fin            TIMESTAMPTZ
) RETURNS TSTZRANGE LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_rappel_journee THEN
            tstzrange(debut_jour(jour_de(p_debut)),
                      debut_jour(jour_de(p_fin) + 1),
                      '[)')
        ELSE
            tstzrange(p_debut, p_fin, '[)')
    END;
$$;
