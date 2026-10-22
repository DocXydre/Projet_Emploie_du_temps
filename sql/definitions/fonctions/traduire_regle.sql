-- -----------------------------------------------------------------------------
-- Une règle en une phrase                                       (CND-2, CND-7)
--
-- « Une fois par mois, un jour sans aucune occupation pour Thomas. »
-- « Tous les 2 à 3 jours, du 01/06 au 31/08, chaque année. »
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION traduire_regle(p_briques      JSONB,
                                          p_validite     DATERANGE DEFAULT NULL,
                                          p_chaque_annee BOOLEAN   DEFAULT FALSE,
                                          p_frequence    JSONB     DEFAULT NULL)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_morceaux TEXT[] := '{}';
    v_texte    TEXT;
BEGIN
    IF p_frequence ? 'fois' THEN
        v_morceaux := v_morceaux || format('%s par %s',
            CASE (p_frequence ->> 'fois')::INTEGER WHEN 1 THEN 'une fois'
                 ELSE (p_frequence ->> 'fois') || ' fois' END,
            p_frequence ->> 'par');
    ELSIF p_frequence ? 'min' THEN
        v_morceaux := v_morceaux || CASE
            WHEN p_frequence ->> 'min' = p_frequence ->> 'max'
                THEN format('tous les %s jours', p_frequence ->> 'min')
            ELSE format('tous les %s à %s jours', p_frequence ->> 'min', p_frequence ->> 'max') END;
    END IF;

    SELECT v_morceaux || COALESCE(array_agg(phrase_brique(b ->> 'nature', b ->> 'pour_qui',
                                                          (b ->> 'id_utilisateur')::INTEGER,
                                                          b -> 'parametres') ORDER BY n), '{}')
      INTO v_morceaux
      FROM jsonb_array_elements(COALESCE(p_briques, '[]')) WITH ORDINALITY AS e(b, n);

    IF p_validite IS NOT NULL THEN
        v_morceaux := v_morceaux || (format('du %s au %s',
                                            to_char(lower(p_validite), CASE WHEN p_chaque_annee THEN 'DD/MM' ELSE 'DD/MM/YYYY' END),
                                            to_char(upper(p_validite) - 1, CASE WHEN p_chaque_annee THEN 'DD/MM' ELSE 'DD/MM/YYYY' END))
                                     || CASE WHEN p_chaque_annee THEN ', chaque année' ELSE '' END);
    END IF;

    v_texte := array_to_string(v_morceaux, ', ');
    RETURN upper(left(v_texte, 1)) || substr(v_texte, 2);
END $$;

COMMENT ON FUNCTION traduire_regle(JSONB, DATERANGE, BOOLEAN, JSONB) IS
    'CND-2 : la règle en une phrase, écrite par la base depuis ses briques, sa fréquence et sa période.';
