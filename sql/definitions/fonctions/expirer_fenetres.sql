CREATE OR REPLACE FUNCTION expirer_fenetres() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_nombre INTEGER;
BEGIN
    -- MES-6 : la fenêtre d'un test suit sa séance. Déplacée plus tard, la
    -- séance garde sa fenêtre ouverte jusqu'au lendemain de son nouveau jour.
    UPDATE fenetre_mesure f SET statut = 'expiree'
     WHERE f.statut = 'ouverte' AND upper(f.periode) <= jour_de(now())
       AND NOT EXISTS (SELECT 1 FROM v_seance_coach s
                        WHERE s.id_occurrence = f.id_occurrence
                          AND s.statut_occurrence IN ('planifiee', 'notifiee')
                          AND s.jour + 1 >= jour_de(now()));
    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION expirer_fenetres() IS
    'MES-3 : à 0h05, clôt comme expirées les fenêtres de mesure dont la période
     est finie. Le coach le relève à la synthèse, sans relance à part.';
