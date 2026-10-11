-- -----------------------------------------------------------------------------
-- Le coût estimé d'un appel, en dollars                               (COA-21)
--
-- Les prix publics par million de tokens, au 9 octobre 2026 : entrée, écriture
-- en cache (5 min), lecture du cache, sortie. Un modèle inconnu est compté au
-- prix de Sonnet. À mettre à jour si les prix changent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cout_appel_usd(p_modele TEXT, p_entree BIGINT, p_lu BIGINT,
                                          p_ecrit BIGINT, p_sortie BIGINT)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT round((
        GREATEST(p_entree - p_lu - p_ecrit, 0) * prix.entree
        + p_ecrit * prix.ecriture + p_lu * prix.lecture + p_sortie * prix.sortie
    ) / 1000000.0, 4)
      FROM (SELECT CASE WHEN p_modele ILIKE '%haiku%' THEN 1.0
                        WHEN p_modele ILIKE '%opus%'  THEN 4.0 ELSE 2.0 END   AS entree,
                   CASE WHEN p_modele ILIKE '%haiku%' THEN 1.25
                        WHEN p_modele ILIKE '%opus%'  THEN 5.0 ELSE 2.5 END   AS ecriture,
                   CASE WHEN p_modele ILIKE '%opus%'  THEN 0.20 ELSE 0.10 END AS lecture,
                   CASE WHEN p_modele ILIKE '%haiku%' THEN 5.0
                        WHEN p_modele ILIKE '%opus%'  THEN 20.0 ELSE 10.0 END AS sortie) prix;
$$;

COMMENT ON FUNCTION cout_appel_usd(TEXT, BIGINT, BIGINT, BIGINT, BIGINT) IS
    'COA-21 : le coût estimé d''un appel, en dollars, d''après les tokens comptés
     et les prix publics du modèle.';
