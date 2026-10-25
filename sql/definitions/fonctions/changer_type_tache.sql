-- -----------------------------------------------------------------------------
-- Changer le type d'une tâche                                   (TAC-21, TAC-25)
--
-- La tâche n'a pas de famille à elle : ce qui la lisait lit le type de base
-- (TAC-29). Une tâche rangée dans « Sassy » compte donc pour les soins du chat.
-- La tâche du sport n'a pas de type, et n'en prend pas.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION changer_type_tache(p_tache INTEGER, p_type INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM tache WHERE id_tache = p_tache AND id_type_tache IS NULL) THEN
        RAISE EXCEPTION 'Une séance de sport n''a pas de type' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM type_tache WHERE id_type_tache = p_type) THEN
        RAISE EXCEPTION 'Ce type de tâche n''existe pas' USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE tache SET id_type_tache = p_type
     WHERE id_tache = p_tache;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tâche % inconnue', p_tache USING ERRCODE = 'no_data_found';
    END IF;
END $$;

COMMENT ON FUNCTION changer_type_tache(INTEGER, INTEGER) IS
    'TAC-25 : range une tâche dans un autre type.';
