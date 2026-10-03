CREATE OR REPLACE TRIGGER occurrence_heriter_tache
    BEFORE INSERT ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_occurrence_heriter_tache();


CREATE OR REPLACE TRIGGER occurrence_transition
    BEFORE UPDATE ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_occurrence_transition();


CREATE OR REPLACE TRIGGER occurrence_close
    BEFORE UPDATE OF statut, date_faite, fenetre, creneau ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_occurrence_close();


CREATE OR REPLACE TRIGGER occurrence_machine_unique
    BEFORE INSERT OR UPDATE OF creneau, statut ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_machine_unique();


CREATE OR REPLACE TRIGGER occurrence_apres_validation
    AFTER UPDATE OF statut ON occurrence
    FOR EACH ROW
    WHEN (NEW.statut = 'faite' AND OLD.statut IS DISTINCT FROM 'faite')
    EXECUTE FUNCTION trg_occurrence_apres_validation();


CREATE OR REPLACE TRIGGER occupation_reverifier_propositions
    AFTER INSERT OR UPDATE OR DELETE ON occupation
    FOR EACH STATEMENT EXECUTE FUNCTION trg_occupation_reverifier();
