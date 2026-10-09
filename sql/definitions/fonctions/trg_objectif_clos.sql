CREATE OR REPLACE FUNCTION trg_objectif_clos() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.statut IN ('atteint', 'abandonne') AND NEW.statut IS DISTINCT FROM OLD.statut THEN
        RAISE EXCEPTION 'Un objectif clos ne se rouvre pas : crée-en un autre'
              USING ERRCODE = 'check_violation', TABLE = 'coach',
                    CONSTRAINT = 'objectif_clos';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION trg_objectif_clos() IS
    'OBJ-9 : un objectif atteint ou abandonné ne change plus de statut.
     L''historique doit rester lisible.';
