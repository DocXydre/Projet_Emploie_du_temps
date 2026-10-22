-- -----------------------------------------------------------------------------
-- Une brique tient-elle ce jour-là                              (CND-3 à CND-6)
--
-- `p_assigne` est la personne à qui l'occurrence revient. Vide, une brique
-- « pour celui qui la fait » tient si l'un des membres pourrait la faire.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION brique_tient(p_nature     TEXT,
                                        p_pour_qui   TEXT,
                                        p_nomme      INTEGER,
                                        p_parametres JSONB,
                                        p_assigne    INTEGER,
                                        p_jour       DATE)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_p      JSONB := COALESCE(p_parametres, '{}'::JSONB);
    v_dow    INTEGER := EXTRACT(ISODOW FROM p_jour)::INTEGER;
    v_jour   INTEGER := EXTRACT(DAY FROM p_jour)::INTEGER;
    v_fin    INTEGER := EXTRACT(DAY FROM (date_trunc('month', p_jour) + INTERVAL '1 month - 1 day'))::INTEGER;
    v_rang   INTEGER;
BEGIN
    CASE p_nature
    WHEN 'jours_semaine' THEN
        RETURN v_dow IN (SELECT j::TEXT::INTEGER FROM jsonb_array_elements(v_p -> 'jours') j);
    WHEN 'dates' THEN
        RETURN p_jour IN (SELECT (d #>> '{}')::DATE FROM jsonb_array_elements(v_p -> 'dates') d);
    WHEN 'jours_interdits' THEN
        RETURN v_dow NOT IN (SELECT j::TEXT::INTEGER
                               FROM jsonb_array_elements(COALESCE(v_p -> 'jours', '[]')) j)
           AND p_jour NOT IN (SELECT (d #>> '{}')::DATE
                                FROM jsonb_array_elements(COALESCE(v_p -> 'dates', '[]')) d);
    WHEN 'jour_du_mois' THEN
        v_rang := (v_p ->> 'rang')::INTEGER;
        IF v_p ? 'jour_semaine' THEN
            -- « Le deuxième samedi », « le dernier dimanche ».
            RETURN v_dow = (v_p ->> 'jour_semaine')::INTEGER
               AND CASE WHEN v_rang > 0 THEN (v_jour - 1) / 7 + 1 = v_rang
                        ELSE (v_fin - v_jour) / 7 + 1 = -v_rang END;
        END IF;
        -- « Le 31 » tombe le dernier jour d'un mois plus court.
        RETURN v_jour = CASE WHEN v_rang > 0 THEN LEAST(v_rang, v_fin)
                             ELSE GREATEST(1, v_fin + v_rang + 1) END;
    ELSE
        -- L'agenda et la présence : pour qui ?
        CASE p_pour_qui
        WHEN 'nomme' THEN
            RETURN brique_tient_pour(p_nature, v_p, p_nomme, p_jour);
        WHEN 'les_deux' THEN
            RETURN NOT EXISTS (SELECT 1 FROM utilisateur u
                                WHERE u.actif
                                  AND NOT brique_tient_pour(p_nature, v_p, u.id_utilisateur, p_jour));
        ELSE
            IF p_assigne IS NOT NULL THEN
                RETURN brique_tient_pour(p_nature, v_p, p_assigne, p_jour);
            END IF;
            RETURN EXISTS (SELECT 1 FROM utilisateur u
                            WHERE u.actif
                              AND brique_tient_pour(p_nature, v_p, u.id_utilisateur, p_jour));
        END CASE;
    END CASE;
END $$;

COMMENT ON FUNCTION brique_tient(TEXT, TEXT, INTEGER, JSONB, INTEGER, DATE) IS
    'CND-3 à CND-6 : vrai si la brique tient ce jour-là pour celui à qui l''occurrence revient.';
