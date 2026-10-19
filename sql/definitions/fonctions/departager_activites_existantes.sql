-- -----------------------------------------------------------------------------
-- Départager les séances reçues avant le départage                     (SAN-15)
--
-- Le départage joue à la réception (migration 069). Les séances reçues avant
-- passent ici une fois, de la plus récente à la plus ancienne : chacune se
-- mesure aux plus anciennes, si bien que la montre l'emporte, puis la première
-- reçue, comme à la réception. Rejouable : un second passage ne change rien.
-- Rend le nombre de doublons et de séances libres retirées.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION departager_activites_existantes()
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    a          RECORD;
    v_avant    INTEGER;
    v_seances  INTEGER;
BEGIN
    SELECT count(*) INTO v_avant FROM activite_sante WHERE doublon_de IS NOT NULL;
    SELECT count(*) INTO v_seances FROM occurrence;
    FOR a IN SELECT id_activite FROM activite_sante ORDER BY id_activite DESC LOOP
        CONTINUE WHEN (SELECT doublon_de IS NOT NULL FROM activite_sante
                        WHERE id_activite = a.id_activite);
        PERFORM departager_activite(a.id_activite);
    END LOOP;
    RETURN jsonb_build_object(
        'doublons', (SELECT count(*) FROM activite_sante WHERE doublon_de IS NOT NULL) - v_avant,
        'seances_retirees', v_seances - (SELECT count(*) FROM occurrence));
END $$;

COMMENT ON FUNCTION departager_activites_existantes() IS
    'SAN-15 : départage une fois les séances de la montre reçues avant la
     migration 069. Rend le nombre de doublons trouvés et de séances libres
     retirées.';
