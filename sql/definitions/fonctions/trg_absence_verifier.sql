-- -----------------------------------------------------------------------------
-- Une absence fait relire toutes les tâches décrites                    (VER-3)
--
-- Une description peut parler des départs et des retours : « à sortir avant
-- que le dernier parte ». Chaque tâche décrite entre donc dans la file, une
-- fois, même sans occurrence ce jour-là.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_absence_verifier() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN
        SELECT DISTINCT d.id_tache
          FROM description_tache d
          JOIN tache ta ON ta.id_tache = d.id_tache AND ta.active
    LOOP
        PERFORM noter_verification(NULL, t.id_tache, 'absence');
    END LOOP;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION trg_absence_verifier() IS
    'VER-3 : une absence déclarée, changée ou retirée fait relire chaque tâche décrite.';
