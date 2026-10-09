CREATE OR REPLACE FUNCTION liberer_seance(p_utilisateur INTEGER, p_occurrence INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    IF NOT EXISTS (SELECT 1 FROM seance se JOIN occurrence o
                       ON o.id_occurrence = se.id_occurrence
                    WHERE se.id_occurrence = p_occurrence
                      AND o.id_utilisateur = p_utilisateur
                      AND o.statut IN ('planifiee', 'notifiee')
                      AND NOT se.libre) THEN
        PERFORM refus_coach('introuvable', 'Séance prévue introuvable, ou déjà close');
    END IF;

    UPDATE ajustement a SET statut = 'caduc'
     WHERE a.id_occurrence = p_occurrence AND a.statut = 'propose';
    DELETE FROM seance_exercice se WHERE se.id_occurrence = p_occurrence;

    -- Même créneau, contenu vide à remplir : c'est maintenant la séance de
    -- l'utilisateur, plus celle du coach.
    UPDATE seance se
       SET auteur = 'utilisateur', libre = TRUE, annoncee = TRUE, etat = 'validee',
           type_seance = 'libre', intensite = NULL, cle = FALSE, est_test = FALSE,
           groupes = '{}', consigne = NULL
     WHERE se.id_occurrence = p_occurrence;
    RETURN p_occurrence;
END $$;

COMMENT ON FUNCTION liberer_seance(INTEGER, INTEGER) IS
    'LIB-7 : « faire autre chose ». La séance prévue devient une séance libre :
     même créneau, exercices vidés, auteur utilisateur.';
