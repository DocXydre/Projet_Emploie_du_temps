-- -----------------------------------------------------------------------------
-- Le lieu d'une séance, pris parmi ceux de sa discipline          (LIE-2, LIE-6)
--
-- Sans lieu donné, le premier du rang. Un lieu qui ne fait pas partie de ceux
-- que le compte a choisis pour cette discipline est refusé.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lieu_de_discipline(p_utilisateur INTEGER, p_discipline VARCHAR,
                                              p_lieu INTEGER DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lieu INTEGER;
BEGIN
    IF p_lieu IS NULL THEN
        SELECT dl.id_lieu INTO v_lieu
          FROM discipline_lieu dl
         WHERE dl.id_utilisateur = p_utilisateur AND dl.discipline = p_discipline
         ORDER BY dl.rang
         LIMIT 1;
        IF v_lieu IS NULL THEN
            PERFORM refus_coach('lieu_non_permis',
                format('Aucun lieu n''est choisi pour la discipline « %s »', p_discipline));
        END IF;
        RETURN v_lieu;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM discipline_lieu dl
                    WHERE dl.id_utilisateur = p_utilisateur
                      AND dl.discipline = p_discipline AND dl.id_lieu = p_lieu) THEN
        PERFORM refus_coach('lieu_non_permis',
            format('Ce lieu ne fait pas partie de ceux de la discipline « %s »', p_discipline));
    END IF;
    RETURN p_lieu;
END $$;

COMMENT ON FUNCTION lieu_de_discipline(INTEGER, VARCHAR, INTEGER) IS
    'LIE-2 : le lieu d''une séance, vérifié parmi ceux de sa discipline. Sans
     lieu donné, le premier du rang.';
