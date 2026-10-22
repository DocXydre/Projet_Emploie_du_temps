-- -----------------------------------------------------------------------------
-- Toutes les briques d'une règle tiennent-elles ce jour-là               (CND-1)
--
-- Les briques arrivent en JSON, `[{nature, pour_qui, id_utilisateur,
-- parametres}]` : une règle en base comme une règle qu'on essaie avant de la
-- poser. Sans assigné, les briques « pour celui qui la fait » doivent tenir
-- toutes pour la même personne : un jour où Thomas a sa matinée libre et
-- Lorette son après-midi ne donne à personne une journée entière.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION briques_tiennent(p_briques JSONB, p_assigne INTEGER, p_jour DATE)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_assigne IS NULL
       AND EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_briques, '[]')) b
                    WHERE b ->> 'pour_qui' = 'assigne') THEN
        RETURN EXISTS (SELECT 1 FROM utilisateur u
                        WHERE u.actif
                          AND briques_tiennent(p_briques, u.id_utilisateur, p_jour));
    END IF;

    RETURN NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(p_briques, '[]')) b
         WHERE NOT brique_tient(b ->> 'nature', b ->> 'pour_qui',
                                (b ->> 'id_utilisateur')::INTEGER,
                                b -> 'parametres', p_assigne, p_jour));
END $$;

COMMENT ON FUNCTION briques_tiennent(JSONB, INTEGER, DATE) IS
    'CND-1 : vrai si toutes les briques tiennent ce jour-là, pour la même personne.';
