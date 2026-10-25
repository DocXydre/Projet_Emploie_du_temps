-- -----------------------------------------------------------------------------
-- Effacer une tâche arrêtée, pour de bon                               (TAC-31)
--
-- La tâche, ses occurrences, ses liens et sa description disparaissent ; une
-- notification déjà lue perd seulement son lien (EXE-13). Le journal garde la
-- ligne de l'effacement, avec le nom de la tâche (trigger `journal_tache`).
-- Seule une tâche arrêtée s'efface : on l'arrête d'abord, ce qui laisse le
-- temps de se raviser.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION effacer_tache(p_tache INTEGER) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    t tache%ROWTYPE;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = p_tache;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tâche % inconnue', p_tache USING ERRCODE = 'no_data_found';
    END IF;
    IF t.id_type_tache IS NULL THEN
        RAISE EXCEPTION 'Les séances de sport ne s''effacent pas ici' USING ERRCODE = 'check_violation';
    END IF;
    IF t.active THEN
        RAISE EXCEPTION '« % » est encore active : arrête-la d''abord', t.libelle
              USING ERRCODE = 'check_violation';
    END IF;

    DELETE FROM occurrence WHERE id_tache = p_tache;
    DELETE FROM tache WHERE id_tache = p_tache;
    RETURN t.libelle;
END $$;

COMMENT ON FUNCTION effacer_tache(INTEGER) IS
    'TAC-31 : efface une tâche arrêtée avec ses occurrences, ses liens et sa description. Rend son nom.';
