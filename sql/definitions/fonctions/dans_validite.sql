-- -----------------------------------------------------------------------------
-- Un jour est-il dans la période d'une règle                            (CND-7)
--
-- Une période « chaque année » se décale d'année en année : du 1er juin au
-- 31 août vaut tous les étés. Elle peut chevaucher le Nouvel An : on essaie
-- donc l'année du jour et la précédente.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dans_validite(p_validite DATERANGE, p_chaque_annee BOOLEAN, p_jour DATE)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_validite IS NULL THEN TRUE
        WHEN NOT p_chaque_annee THEN p_validite @> p_jour
        ELSE EXISTS (
            SELECT 1
              FROM (VALUES (EXTRACT(YEAR FROM p_jour)::INTEGER - EXTRACT(YEAR FROM lower(p_validite))::INTEGER),
                           (EXTRACT(YEAR FROM p_jour)::INTEGER - EXTRACT(YEAR FROM lower(p_validite))::INTEGER - 1)
                   ) AS d(ans)
             WHERE daterange((lower(p_validite) + make_interval(years => d.ans))::DATE,
                             (upper(p_validite) + make_interval(years => d.ans))::DATE, '[)') @> p_jour)
    END;
$$;

COMMENT ON FUNCTION dans_validite(DATERANGE, BOOLEAN, DATE) IS
    'CND-7 : vrai si le jour est dans la période de la règle, décalée d''année en année si elle revient chaque année.';
