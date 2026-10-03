-- -----------------------------------------------------------------------------
-- Les périodes où personne n'est là, en entier                          (ABS-8)
--
-- `fenetres_appartement_vide` coupe ses fenêtres à l'instant présent : une
-- absence commencée il y a trois jours y paraît commencer maintenant. Pour
-- savoir depuis combien de temps l'appartement est vide, il faut la période
-- entière.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION absences_communes(p_depuis TIMESTAMPTZ, p_jusqu_a TIMESTAMPTZ)
RETURNS SETOF TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_commun TSTZMULTIRANGE;
    v_sienne TSTZMULTIRANGE;
    u        RECORD;
BEGIN
    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif LOOP
        SELECT COALESCE(range_agg(a.periode), '{}'::TSTZMULTIRANGE) INTO v_sienne
          FROM absence a
         WHERE a.id_utilisateur = u.id_utilisateur
           AND a.periode && tstzrange(p_depuis, p_jusqu_a, '[)');

        IF v_sienne = '{}'::TSTZMULTIRANGE THEN
            RETURN;
        END IF;

        v_commun := CASE WHEN v_commun IS NULL THEN v_sienne
                         ELSE v_commun * v_sienne END;
    END LOOP;

    IF v_commun IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT r FROM unnest(v_commun) r;
END $$;

COMMENT ON FUNCTION absences_communes(TIMESTAMPTZ, TIMESTAMPTZ) IS
    'ABS-8 : les périodes où tous les comptes actifs sont absents, non coupées,
     parmi les absences qui touchent l''intervalle donné.';
