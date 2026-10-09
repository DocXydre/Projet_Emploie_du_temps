CREATE OR REPLACE FUNCTION marquer_important(p_utilisateur INTEGER, p_raison TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM exiger_coach(p_utilisateur);
    IF btrim(COALESCE(p_raison, '')) = '' THEN
        PERFORM refus_coach('requete_invalide', 'Dis pourquoi c''est important');
    END IF;
    PERFORM tracer_coach(p_utilisateur, 'important', NULL,
                         jsonb_build_object('raison', left(btrim(p_raison), 300)));
END $$;

COMMENT ON FUNCTION marquer_important(INTEGER, TEXT) IS
    'MEM-8 : le coach marque l''échange en cours comme important (niveau 3) :
     les résumés le garderont.';
