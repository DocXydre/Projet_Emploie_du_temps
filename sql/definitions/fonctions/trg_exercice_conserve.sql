CREATE OR REPLACE FUNCTION trg_exercice_conserve() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Un exercice ne se supprime pas, il se désactive (colonne actif) : '
                    'les saisies passées s''y réfèrent'
          USING ERRCODE = 'check_violation';
END $$;

COMMENT ON FUNCTION trg_exercice_conserve() IS
    'EXO-3 : refuse la suppression d''un exercice et renvoie vers sa désactivation.';
