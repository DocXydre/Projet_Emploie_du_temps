CREATE OR REPLACE FUNCTION expirer_fenetres() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_nombre INTEGER;
BEGIN
    UPDATE fenetre_mesure f SET statut = 'expiree'
     WHERE f.statut = 'ouverte' AND upper(f.periode) <= jour_de(now());
    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION expirer_fenetres() IS
    'MES-3 : à 0h05, clôt comme expirées les fenêtres de mesure dont la période
     est finie. Le coach le relève à la synthèse, sans relance à part.';
