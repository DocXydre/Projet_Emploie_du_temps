-- -----------------------------------------------------------------------------
-- Mettre dans la file des vérifications                                 (VER-3)
--
-- Une occurrence d'une tâche décrite, ou la tâche entière. Une seule ligne en
-- attente par occurrence et par tâche : la file dit ce qui est à relire, pas
-- combien de fois. Ce que HAL vient de faire lui-même n'y entre pas : il le
-- signale à la transaction par `planif.par_hal`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION noter_verification(p_occurrence INTEGER, p_tache INTEGER, p_raison TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_tache INTEGER := p_tache;
BEGIN
    IF current_setting('planif.par_hal', TRUE) = '1' THEN
        RETURN;
    END IF;
    IF p_occurrence IS NOT NULL THEN
        SELECT id_tache INTO v_tache FROM occurrence WHERE id_occurrence = p_occurrence;
    END IF;
    IF v_tache IS NULL OR NOT tache_decrite(v_tache) THEN
        RETURN;
    END IF;

    IF p_occurrence IS NOT NULL THEN
        INSERT INTO verification_tache (id_occurrence, raison)
        VALUES (p_occurrence, p_raison)
        ON CONFLICT (id_occurrence) WHERE traitee_le IS NULL AND id_occurrence IS NOT NULL DO NOTHING;
    ELSE
        INSERT INTO verification_tache (id_tache, raison)
        VALUES (v_tache, p_raison)
        ON CONFLICT (id_tache) WHERE traitee_le IS NULL AND id_tache IS NOT NULL DO NOTHING;
    END IF;
END $$;

COMMENT ON FUNCTION noter_verification(INTEGER, INTEGER, TEXT) IS
    'VER-3 : met une occurrence, ou une tâche entière, dans la file des vérifications, si sa tâche est décrite.';
