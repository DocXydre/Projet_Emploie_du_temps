-- -----------------------------------------------------------------------------
-- La séance de la montre que désigne la clé de Santé                     (SAN-3)
--
-- Le détail d'une séance (séries, étapes, tracé) arrive après elle, sous la
-- même clé. Une clé inconnue est refusée : l'appli renvoie d'abord la séance.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION activite_par_cle(p_utilisateur INTEGER, p_cle VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_activite BIGINT;
BEGIN
    SELECT id_activite INTO v_activite FROM activite_sante
     WHERE id_utilisateur = p_utilisateur AND cle_externe = p_cle;
    IF v_activite IS NULL THEN
        PERFORM refus_coach('introuvable',
            'Séance de la montre inconnue : envoie la séance avant son détail');
    END IF;
    RETURN v_activite;
END $$;

COMMENT ON FUNCTION activite_par_cle(INTEGER, VARCHAR) IS
    'SAN-3 : la séance de la montre d''un compte, par la clé que lui donne
     Santé. Refus « introuvable » si elle n''a pas encore été reçue.';
