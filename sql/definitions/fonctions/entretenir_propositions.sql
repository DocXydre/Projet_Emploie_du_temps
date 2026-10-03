-- -----------------------------------------------------------------------------
-- L'entretien enchaîne                                                  (WKD-3)
--
-- Même signature que dans la migration 012, pour ne pas créer une seconde
-- fonction du même nom à côté de la première.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION entretenir_propositions() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_touchees INTEGER := 0;
    v_lot      INTEGER;
BEGIN
    UPDATE proposition
       SET statut = 'realisee'
     WHERE statut = 'proposee'
       AND EXISTS (SELECT 1 FROM absence a
                    WHERE a.id_utilisateur = proposition.id_utilisateur
                      AND a.periode && proposition.periode);
    GET DIAGNOSTICS v_lot = ROW_COUNT;
    v_touchees := v_lot;

    UPDATE proposition
       SET statut = 'perimee'
     WHERE statut IN ('proposee', 'ecartee')
       AND upper(periode) < now();
    GET DIAGNOSTICS v_lot = ROW_COUNT;
    v_touchees := v_touchees + v_lot;

    -- WKD-9 : après avoir soldé ce qui devait l'être, vérifier ce qui reste.
    RETURN v_touchees + reverifier_propositions();
END $$;
