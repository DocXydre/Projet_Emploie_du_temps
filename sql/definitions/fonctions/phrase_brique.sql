-- -----------------------------------------------------------------------------
-- Une brique en clair                                                   (CND-2)
--
-- « le mardi ou le jeudi », « un jour sans aucune occupation pour Thomas ».
-- C'est la base qui écrit la traduction d'une règle, pas le modèle : ce qu'on
-- accepte est ce que la base appliquera.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION phrase_brique(p_nature     TEXT,
                                         p_pour_qui   TEXT,
                                         p_nomme      INTEGER,
                                         p_parametres JSONB)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    JOURS CONSTANT TEXT[] := ARRAY['lundi', 'mardi', 'mercredi', 'jeudi',
                                   'vendredi', 'samedi', 'dimanche'];
    RANGS CONSTANT TEXT[] := ARRAY['premier', 'deuxième', 'troisième', 'quatrième', 'cinquième'];
    v_p      JSONB := COALESCE(p_parametres, '{}'::JSONB);
    v_qui    TEXT;
    v_rang   INTEGER;
    v_texte  TEXT;
    v_liste  TEXT[];
BEGIN
    v_qui := CASE p_pour_qui
                 WHEN 'nomme' THEN ' pour ' || (SELECT nom FROM utilisateur WHERE id_utilisateur = p_nomme)
                 WHEN 'les_deux' THEN ' pour vous deux'
                 ELSE ''
             END;

    CASE p_nature
    WHEN 'jours_semaine' THEN
        SELECT array_agg('le ' || JOURS[j::TEXT::INTEGER] ORDER BY j::TEXT::INTEGER) INTO v_liste
          FROM jsonb_array_elements(v_p -> 'jours') j;
        RETURN liste_en_clair(v_liste, 'ou');
    WHEN 'dates' THEN
        SELECT array_agg('le ' || to_char((d #>> '{}')::DATE, 'DD/MM/YYYY') ORDER BY (d #>> '{}')::DATE)
          INTO v_liste
          FROM jsonb_array_elements(v_p -> 'dates') d;
        RETURN liste_en_clair(v_liste, 'ou');
    WHEN 'jours_interdits' THEN
        SELECT array_agg(x) INTO v_liste FROM (
            SELECT 'le ' || JOURS[j::TEXT::INTEGER] AS x
              FROM jsonb_array_elements(COALESCE(v_p -> 'jours', '[]')) j
            UNION ALL
            SELECT 'le ' || to_char((d #>> '{}')::DATE, 'DD/MM/YYYY')
              FROM jsonb_array_elements(COALESCE(v_p -> 'dates', '[]')) d) l;
        RETURN 'jamais ' || liste_en_clair(v_liste, 'ni');
    WHEN 'jour_du_mois' THEN
        v_rang := (v_p ->> 'rang')::INTEGER;
        IF v_p ? 'jour_semaine' THEN
            v_texte := JOURS[(v_p ->> 'jour_semaine')::INTEGER];
            RETURN CASE WHEN v_rang > 0 THEN format('le %s %s du mois', RANGS[v_rang], v_texte)
                        WHEN v_rang = -1 THEN format('le dernier %s du mois', v_texte)
                        WHEN v_rang = -2 THEN format('l''avant-dernier %s du mois', v_texte)
                        ELSE format('le %s %s avant la fin du mois', RANGS[-v_rang], v_texte) END;
        END IF;
        RETURN CASE WHEN v_rang = 1 THEN 'le 1er du mois'
                    WHEN v_rang > 1 THEN format('le %s du mois', v_rang)
                    WHEN v_rang = -1 THEN 'le dernier jour du mois'
                    WHEN v_rang = -2 THEN 'l''avant-dernier jour du mois'
                    ELSE format('%s jours avant la fin du mois', -v_rang - 1) END;
    WHEN 'journee_vide' THEN
        RETURN 'un jour sans aucune occupation' || v_qui;
    WHEN 'sans_cours_ni_travail' THEN
        RETURN 'un jour sans cours ni travail' || v_qui;
    WHEN 'demi_journee' THEN
        RETURN CASE v_p ->> 'partie' WHEN 'matin' THEN 'avec la matinée libre'
                                     ELSE 'avec l''après-midi libre' END || v_qui;
    WHEN 'heures_max' THEN
        RETURN format('un jour d''au plus %s h de cours ou de travail',
                      trim_scale((v_p ->> 'heures')::NUMERIC)) || v_qui;
    WHEN 'veille_sans_cours' THEN
        RETURN 'la veille d''un jour sans cours' || v_qui;
    WHEN 'lendemain_sans_cours' THEN
        RETURN 'le lendemain d''un jour sans cours' || v_qui;
    WHEN 'temps_libre_min' THEN
        RETURN 'avec au moins ' || duree_en_clair((v_p ->> 'minutes')::INTEGER) || ' de libre' || v_qui;
    WHEN 'autre_absent' THEN
        RETURN CASE WHEN p_pour_qui = 'nomme'
                    THEN format('quand %s est seul à la maison',
                                (SELECT nom FROM utilisateur WHERE id_utilisateur = p_nomme))
                    ELSE 'quand l''autre n''est pas là' END;
    WHEN 'tous_presents' THEN
        RETURN 'quand vous êtes là tous les deux';
    WHEN 'au_retour' THEN
        RETURN 'au retour d''un voyage' || v_qui;
    WHEN 'avant_depart' THEN
        RETURN CASE WHEN (v_p ->> 'jours_avant')::INTEGER = 0 THEN 'le jour d''un départ'
                    ELSE format('dans les %s jours avant un départ', v_p ->> 'jours_avant') END || v_qui;
    ELSE
        RETURN p_nature;
    END CASE;
END $$;

COMMENT ON FUNCTION phrase_brique(TEXT, TEXT, INTEGER, JSONB) IS
    'CND-2 : la brique en clair, telle que la traduction d''une règle la dit.';
