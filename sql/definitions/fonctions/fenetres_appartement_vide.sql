-- -----------------------------------------------------------------------------
-- Quand l'appartement se vide                                          (TAC-12)
--
-- L'intersection des absences de tout le monde. Si une seule personne reste,
-- il n'y a pas de fenêtre : c'est elle qui sortira le sac, et le placement
-- ordinaire s'en charge.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fenetres_appartement_vide(p_horizon_jours INTEGER DEFAULT 35)
RETURNS SETOF TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_horizon TSTZRANGE;
    v_commun  TSTZMULTIRANGE;
    v_sienne  TSTZMULTIRANGE;
    u         RECORD;
BEGIN
    v_horizon := tstzrange(now(), now() + make_interval(days => p_horizon_jours), '[)');

    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif LOOP
        SELECT COALESCE(range_agg(a.periode), '{}'::TSTZMULTIRANGE) INTO v_sienne
          FROM absence a
         WHERE a.id_utilisateur = u.id_utilisateur
           AND a.periode && v_horizon;

        -- Quelqu'un reste : inutile de continuer, l'appartement ne se vide pas.
        IF v_sienne = '{}'::TSTZMULTIRANGE THEN
            RETURN;
        END IF;

        v_commun := CASE WHEN v_commun IS NULL THEN v_sienne
                         ELSE v_commun * v_sienne END;
    END LOOP;

    IF v_commun IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT r FROM unnest(v_commun * multirange(v_horizon)) r;
END $$;

COMMENT ON FUNCTION fenetres_appartement_vide IS
    'Les périodes où personne n''est là : l''intersection des absences de tous
     les comptes actifs (TAC-12).';
