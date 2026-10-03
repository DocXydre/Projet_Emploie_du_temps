-- -----------------------------------------------------------------------------
-- Disponibilités communes à tous les utilisateurs actifs                 (PLA-9)
--
-- Le grand nettoyage se fait à deux : il ne suffit pas que Thomas soit libre,
-- il faut que Lorette le soit au même moment. On intersecte donc les
-- disponibilités de chacun, multirange par multirange.
--
-- L'intersection est vide dès qu'une seule personne est occupée : on sort de
-- la boucle sans interroger les suivantes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION disponibilites_communes(
    p_debut TIMESTAMPTZ,
    p_fin   TIMESTAMPTZ
) RETURNS SETOF TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    u        RECORD;
    v_commun TSTZMULTIRANGE := tstzmultirange(tstzrange(p_debut, p_fin, '[)'));
    v_perso  TSTZMULTIRANGE;
BEGIN
    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif ORDER BY id_utilisateur LOOP

        SELECT COALESCE(range_agg(d), '{}'::TSTZMULTIRANGE) INTO v_perso
          FROM disponibilites(u.id_utilisateur, p_debut, p_fin) d;

        v_commun := v_commun * v_perso;

        EXIT WHEN v_commun = '{}'::TSTZMULTIRANGE;
    END LOOP;

    RETURN QUERY SELECT unnest(v_commun);
END $$;
