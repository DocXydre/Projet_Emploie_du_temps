-- La semaine (du lundi au dimanche) ou le mois civil qui contient le jour (CND-4).
CREATE OR REPLACE FUNCTION periode_de(p_periode TEXT, p_jour DATE)
RETURNS DATERANGE LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_periode
        WHEN 'semaine' THEN daterange(lundi_de(p_jour), lundi_de(p_jour) + 7, '[)')
        ELSE daterange(date_trunc('month', p_jour)::DATE,
                       (date_trunc('month', p_jour) + INTERVAL '1 month')::DATE, '[)')
    END;
$$;

COMMENT ON FUNCTION periode_de(TEXT, DATE) IS
    'CND-4 : la semaine ou le mois civil qui contient le jour.';
