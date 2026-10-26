-- -----------------------------------------------------------------------------
-- Une absence déclarée et les séances du coach                        (PLN-15)
--
-- Les séances proposées qu'elle couvre sont retirées, sauf celles qui se font
-- là où l'on va : la course dehors, une salle proche (SPT-38). Les séances
-- validées loin de là sont signalées : c'est à l'utilisateur de dire s'il
-- s'entraîne là où il va.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_absence_seances() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_validees INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM utilisateur u
                    WHERE u.id_utilisateur = NEW.id_utilisateur AND u.coach_actif) THEN
        RETURN NULL;
    END IF;

    DELETE FROM occurrence o
     USING seance se
     WHERE se.id_occurrence = o.id_occurrence
       AND o.id_utilisateur = NEW.id_utilisateur
       AND se.auteur = 'coach' AND se.etat = 'proposee'
       AND o.statut IN ('planifiee', 'notifiee')
       AND o.debut_seance > now()
       AND NEW.periode @> o.debut_seance
       AND NOT lieu_de_sport_possible(NEW.id_utilisateur, o.id_lieu, o.debut_seance);

    SELECT count(*) INTO v_validees
      FROM occurrence o JOIN seance se ON se.id_occurrence = o.id_occurrence
     WHERE o.id_utilisateur = NEW.id_utilisateur
       AND se.etat = 'validee'
       AND o.statut IN ('planifiee', 'notifiee')
       AND o.debut_seance > now()
       AND NEW.periode @> o.debut_seance
       AND NOT lieu_de_sport_possible(NEW.id_utilisateur, o.id_lieu, o.debut_seance);
    IF v_validees > 0 AND TG_OP = 'INSERT' THEN
        INSERT INTO notification (id_utilisateur, type, contenu)
        VALUES (NEW.id_utilisateur, 'coach',
                format('%s séance(s) validée(s) tombent pendant ton absence. Dis-moi si '
                       || 'tu t''entraînes là où tu vas, sinon supprime-les.', v_validees));
    END IF;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION trg_absence_seances() IS
    'PLN-15, SPT-38 : une absence retire les séances proposées qu''elle couvre et
     signale les séances validées, sauf celles qui se font là où l''on va.';
