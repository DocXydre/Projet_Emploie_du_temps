CREATE OR REPLACE FUNCTION liberer_appels_bloques(p_minutes INTEGER DEFAULT 10)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_nombre INTEGER;
BEGIN
    UPDATE appel_coach a
       SET statut = 'echoue', fin = now(),
           motif_echec = 'Appel resté en cours après un arrêt de l''API'
     WHERE a.statut = 'en_cours'
       AND a.debut < now() - make_interval(mins => p_minutes);
    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION liberer_appels_bloques(INTEGER) IS
    'COA-22 : un appel resté en cours après un arrêt brutal bloquerait le
     compte. Passé son délai, il est clos comme échoué.';
