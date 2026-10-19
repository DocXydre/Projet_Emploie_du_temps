-- -----------------------------------------------------------------------------
-- Un lot de données de santé a une taille raisonnable            (SAN-11 à 16)
--
-- L'appli envoie l'historique par paquets. Un paquet vide ou trop gros est
-- une erreur de l'appli, pas une donnée : il est refusé en entier.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION verifier_lot_sante(p_lot JSONB)
RETURNS INTEGER LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_lot IS NULL OR jsonb_typeof(p_lot) <> 'array' THEN
        PERFORM refus_coach('requete_invalide', 'Un envoi de santé est une liste');
    END IF;
    IF jsonb_array_length(p_lot) > 5000 THEN
        PERFORM refus_coach('requete_invalide',
            'Un envoi de santé porte au plus 5 000 lignes : découpe-le en paquets');
    END IF;
    RETURN jsonb_array_length(p_lot);
END $$;

COMMENT ON FUNCTION verifier_lot_sante(JSONB) IS
    'SAN-11 à SAN-16 : refuse un lot qui n''est pas une liste ou qui dépasse
     5 000 lignes. Rend le nombre de lignes.';
