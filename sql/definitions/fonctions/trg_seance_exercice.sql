-- -----------------------------------------------------------------------------
-- Les exercices prévus d'une séance                              (EXO-5, SEC-3)
--
-- Avant : un exercice désactivé ne s'ajoute pas à une séance. Après : les
-- groupes de la séance de musculation sont recopiés des groupes principaux de
-- ses exercices. C'est ce que la règle des séances dures compare.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_seance_exercice() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_occurrence INTEGER;
    v_groupes    TEXT[];
BEGIN
    IF TG_WHEN = 'BEFORE' THEN
        IF NOT EXISTS (SELECT 1 FROM exercice e
                        WHERE e.id_exercice = NEW.id_exercice AND e.actif) THEN
            RAISE EXCEPTION 'Cet exercice est désactivé au catalogue'
                  USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;

    v_occurrence := CASE WHEN TG_OP = 'DELETE' THEN OLD.id_occurrence
                         ELSE NEW.id_occurrence END;

    SELECT array_agg(DISTINCT e.groupe_principal) INTO v_groupes
      FROM seance_exercice se JOIN exercice e ON e.id_exercice = se.id_exercice
     WHERE se.id_occurrence = v_occurrence;

    -- Sans exercices, la séance redevient une esquisse et garde ses groupes.
    IF v_groupes IS NOT NULL THEN
        UPDATE seance s SET groupes = v_groupes
         WHERE s.id_occurrence = v_occurrence
           AND s.discipline = 'musculation'
           AND s.groupes IS DISTINCT FROM v_groupes;
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION trg_seance_exercice() IS
    'EXO-5, SEC-3 : refuse un exercice désactivé, et recopie sur la séance de
     musculation les groupes principaux de ses exercices.';
