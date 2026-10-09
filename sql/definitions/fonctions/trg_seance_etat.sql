-- -----------------------------------------------------------------------------
-- L'état d'une séance commande son épingle et son titre       (PLN-3, PLN-4)
--
-- Proposée, la séance occupe son créneau mais n'est pas épinglée. Validée,
-- elle l'est. Son titre au planning dit « à valider » tant qu'elle ne l'est
-- pas (NOT-13). Une séance ne détaille qu'une occurrence de sport.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_seance_etat() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NOT EXISTS (
            SELECT 1 FROM occurrence o JOIN tache t ON t.id_tache = o.id_tache
             WHERE o.id_occurrence = NEW.id_occurrence AND t.categorie = 'sport') THEN
        RAISE EXCEPTION 'Une séance ne détaille qu''une occurrence de sport'
              USING ERRCODE = 'check_violation';
    END IF;

    UPDATE occurrence o
       SET epinglee = (NEW.etat = 'validee' AND o.creneau IS NOT NULL),
           titre    = titre_seance(NEW.discipline, NEW.etat, NEW.libre)
     WHERE o.id_occurrence = NEW.id_occurrence
       AND (o.epinglee IS DISTINCT FROM (NEW.etat = 'validee' AND o.creneau IS NOT NULL)
            OR o.titre IS DISTINCT FROM titre_seance(NEW.discipline, NEW.etat, NEW.libre));
    RETURN NULL;
END $$;

COMMENT ON FUNCTION trg_seance_etat() IS
    'PLN-3, PLN-4 : une séance validée est épinglée, une séance proposée ne
     l''est pas. Le titre au planning suit (NOT-13).';
