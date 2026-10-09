CREATE OR REPLACE FUNCTION valider_seance(p_utilisateur INTEGER, p_occurrence INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM seance_exercice x WHERE x.id_occurrence = p_occurrence) THEN
        PERFORM refus_coach('seance_a_detailler',
            'Cette séance n''est encore qu''une esquisse');
    END IF;

    UPDATE seance se SET etat = 'validee'
      FROM occurrence o
     WHERE o.id_occurrence = se.id_occurrence
       AND se.id_occurrence = p_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND se.etat = 'proposee'
       AND o.statut IN ('planifiee', 'notifiee');
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Séance proposée introuvable');
    END IF;
    RETURN p_occurrence;
END $$;

COMMENT ON FUNCTION valider_seance(INTEGER, INTEGER) IS
    'PLN-10 : valide une seule séance proposée, d''un bouton. C''est le cas
     d''une séance proposée à nouveau après une séance pas faite.';
