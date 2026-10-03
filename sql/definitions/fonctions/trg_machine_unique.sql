-- -----------------------------------------------------------------------------
-- Une seule machine par jour                                             (UNI-12)
--
-- Le chevauchement ne suffit pas : deux lessives à 21h45 et 23h00 ne se
-- chevauchent pas mais ne peuvent pas tourner le même soir.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_machine_unique() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.utilise_machine
       AND NEW.creneau IS NOT NULL
       AND NEW.statut IN ('planifiee', 'notifiee')
       AND machine_occupee(jour_de(lower(NEW.creneau)), NEW.id_occurrence) THEN

        RAISE EXCEPTION 'Une seule machine par jour : le % est déjà pris',
              to_char(lower(NEW.creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM')
              USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END $$;
