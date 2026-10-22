-- CND-3 à CND-6 : une brique mal formée ne s'écrit pas, d'où qu'elle vienne.
CREATE OR REPLACE FUNCTION trg_brique_regle_verifier()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_motif TEXT;
BEGIN
    v_motif := motif_brique(NEW.nature, NEW.pour_qui, NEW.id_utilisateur, NEW.parametres);
    IF v_motif IS NOT NULL THEN
        RAISE EXCEPTION '%', v_motif USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
