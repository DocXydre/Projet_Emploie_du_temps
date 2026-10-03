-- -----------------------------------------------------------------------------
-- Une occurrence close ne se touche plus                                 (EXE-5)
--
-- Comparer les valeurs avant et après ne suffit pas : now() est figé pour
-- toute la transaction, donc revalider une occurrence dans la même
-- transaction réécrit date_faite avec la même valeur, et le changement passe
-- inaperçu.
--
-- On passe donc par un trigger de colonnes : PostgreSQL le déclenche dès que
-- l'une d'elles figure dans le SET, que la valeur change ou non.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occurrence_close() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.statut IN ('faite', 'reportee', 'abandonnee') THEN
        RAISE EXCEPTION 'L''occurrence % est close (%) et ne peut plus être modifiée',
              OLD.id_occurrence, OLD.statut
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
