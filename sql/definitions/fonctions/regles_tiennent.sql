-- -----------------------------------------------------------------------------
-- Les règles d'une tâche tiennent-elles ce jour-là                      (CND-8)
--
-- Toutes les règles actives dont la période contient le jour. Une tâche sans
-- règle, ou dont aucune règle n'est en vigueur ce jour-là, est libre.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION regles_tiennent(p_tache INTEGER, p_assigne INTEGER, p_jour DATE)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_regles JSONB;
BEGIN
    SELECT jsonb_agg(briques) INTO v_regles
      FROM (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'nature', b.nature, 'pour_qui', b.pour_qui,
                       'id_utilisateur', b.id_utilisateur, 'parametres', b.parametres))
                       FILTER (WHERE b.id_brique_regle IS NOT NULL), '[]') AS briques
              FROM regle_tache r
              LEFT JOIN brique_regle b ON b.id_regle_tache = r.id_regle_tache
             WHERE r.id_tache = p_tache
               AND r.etat = 'active'
               AND dans_validite(r.validite, r.chaque_annee, p_jour)
             GROUP BY r.id_regle_tache) r;

    IF v_regles IS NULL THEN
        RETURN TRUE;
    END IF;

    -- Toutes les règles ensemble, pour une même personne : on les met bout à
    -- bout, comme une seule liste de briques.
    RETURN briques_tiennent(
        (SELECT jsonb_agg(b) FROM jsonb_array_elements(v_regles) r,
                                  jsonb_array_elements(r) b),
        p_assigne, p_jour);
END $$;

COMMENT ON FUNCTION regles_tiennent(INTEGER, INTEGER, DATE) IS
    'CND-8 : vrai si toutes les règles en vigueur de la tâche tiennent ce jour-là pour cette personne.';
