-- -----------------------------------------------------------------------------
-- Laquelle de deux séances identiques compte                  (SAN-15, MON-13)
--
-- La montre d'abord, puis une appli qui écrit dans Santé (Strava), puis une
-- séance déclarée à la main : une saisie de mémoire vaut moins qu'une mesure.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rang_activite(p_details JSONB)
RETURNS SMALLINT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN activite_de_la_montre(p_details) THEN 2
                WHEN activite_a_la_main(p_details) THEN 0
                ELSE 1 END::SMALLINT
$$;

COMMENT ON FUNCTION rang_activite(JSONB) IS
    'SAN-15, MON-13 : 2 pour la montre, 1 pour une autre appli, 0 pour une
     séance déclarée à la main. La plus haute compte.';
