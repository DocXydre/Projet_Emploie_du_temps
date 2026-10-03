-- -----------------------------------------------------------------------------
-- Contrôle des transitions de statut                            (EXE-1, EXE-5)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occurrence_transition() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    -- EXE-1 : on ne valide pas une tâche dans le futur. Ce contrôle ne peut pas
    -- être un CHECK, now() n'étant pas immutable.
    IF NEW.date_faite IS NOT NULL AND NEW.date_faite > now() THEN
        RAISE EXCEPTION 'Une tâche ne peut pas être validée dans le futur'
              USING ERRCODE = 'check_violation';
    END IF;

    -- EXE-6 : le compteur de relances ne redescend jamais.
    IF NEW.nb_relances < OLD.nb_relances THEN
        RAISE EXCEPTION 'Le compteur de relances ne peut pas diminuer'
              USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END $$;
