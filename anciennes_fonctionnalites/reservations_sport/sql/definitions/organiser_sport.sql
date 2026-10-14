-- SPT-18 : trois semaines, toujours.
CREATE OR REPLACE FUNCTION organiser_sport(p_utilisateur INTEGER DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    u        INTEGER;
    i        INTEGER;
    v_creees INTEGER := 0;
BEGIN
    FOR u IN SELECT s FROM sportifs() s
              WHERE p_utilisateur IS NULL OR s = p_utilisateur LOOP
        FOR i IN 0 .. 2 LOOP
            v_creees := v_creees + organiser_sport_semaine(u, lundi_de(jour_de(now())) + 7 * i);
        END LOOP;
    END LOOP;
    RETURN v_creees;
END $$;
