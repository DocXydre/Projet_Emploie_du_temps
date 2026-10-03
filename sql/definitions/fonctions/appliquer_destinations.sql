-- Lorette va à Saint-Dié, pas à Lusse. Par une fonction, et non par un UPDATE
-- direct : les comptes n'existent pas forcément au moment des migrations, et
-- l'API rejoue ceci à chaque démarrage, comme les assignations (COL-16).
CREATE OR REPLACE FUNCTION appliquer_destinations() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_touchees INTEGER;
BEGIN
    UPDATE utilisateur
       SET lieu_famille = 'Saint-Dié', gare_famille = 'SAINT_DIE'
     WHERE pseudo = 'lorette'
       AND lieu_famille IS NULL
       AND gare_famille IS NULL;

    GET DIAGNOSTICS v_touchees = ROW_COUNT;
    RETURN v_touchees;
END $$;

COMMENT ON FUNCTION appliquer_destinations IS
    'Pose les destinations connues sur les comptes qui n''en ont pas. Rejouée
     au démarrage, elle rattrape les comptes créés après la migration (TRJ-8).';
