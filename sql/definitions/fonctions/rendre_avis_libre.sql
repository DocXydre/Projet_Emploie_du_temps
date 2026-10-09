CREATE OR REPLACE FUNCTION rendre_avis_libre(p_utilisateur INTEGER, p_occurrence INTEGER,
                                             p_avis VARCHAR, p_detail TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    UPDATE seance se SET avis_libre = p_avis, avis_detail = p_detail
      FROM occurrence o
     WHERE o.id_occurrence = se.id_occurrence
       AND se.id_occurrence = p_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND se.libre;
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Séance libre introuvable');
    END IF;

    PERFORM tracer_coach(p_utilisateur, 'avis_seance_libre', p_occurrence);
    RETURN p_occurrence;
END $$;

COMMENT ON FUNCTION rendre_avis_libre(INTEGER, INTEGER, VARCHAR, TEXT) IS
    'LIB-8, LIB-9 : enregistre l''avis du coach sur une séance libre :
     conforme, acceptable, ou à éviter la prochaine fois. Jamais un refus.';
