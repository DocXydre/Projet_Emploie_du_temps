-- « le mardi, le jeudi ou le samedi ».
CREATE OR REPLACE FUNCTION liste_en_clair(p_elements TEXT[], p_liaison TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN cardinality(p_elements) IS NULL OR cardinality(p_elements) = 0 THEN ''
        WHEN cardinality(p_elements) = 1 THEN p_elements[1]
        ELSE array_to_string(p_elements[1:cardinality(p_elements) - 1], ', ')
             || ' ' || p_liaison || ' ' || p_elements[cardinality(p_elements)]
    END;
$$;
