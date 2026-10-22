-- 90 minutes : « 1 h 30 » ; 45 : « 45 min » ; 120 : « 2 h ».
CREATE OR REPLACE FUNCTION duree_en_clair(p_minutes INTEGER)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_minutes < 60 THEN p_minutes || ' min'
        WHEN p_minutes % 60 = 0 THEN (p_minutes / 60) || ' h'
        ELSE (p_minutes / 60) || ' h ' || lpad((p_minutes % 60)::TEXT, 2, '0')
    END;
$$;
