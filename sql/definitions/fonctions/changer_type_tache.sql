-- -----------------------------------------------------------------------------
-- Changer le type d'une tâche                                   (TAC-21, TAC-25)
--
-- La famille technique suit le type : une tâche rangée dans « Sassy » compte
-- pour les soins du chat, une tâche rangée dans un type du foyer compte comme
-- du ménage dans la répartition (PLA-10).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION changer_type_tache(p_tache INTEGER, p_type INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_categorie TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM tache WHERE id_tache = p_tache AND categorie = 'sport') THEN
        RAISE EXCEPTION 'Une séance de sport n''a pas de type' USING ERRCODE = 'check_violation';
    END IF;
    SELECT categorie INTO v_categorie FROM type_tache WHERE id_type_tache = p_type;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ce type de tâche n''existe pas' USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE tache SET id_type_tache = p_type, categorie = v_categorie
     WHERE id_tache = p_tache;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tâche % inconnue', p_tache USING ERRCODE = 'no_data_found';
    END IF;
END $$;

COMMENT ON FUNCTION changer_type_tache(INTEGER, INTEGER) IS
    'TAC-25 : range une tâche dans un autre type ; sa famille technique suit.';
