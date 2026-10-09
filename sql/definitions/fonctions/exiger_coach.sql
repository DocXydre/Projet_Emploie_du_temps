CREATE OR REPLACE FUNCTION exiger_coach(p_utilisateur INTEGER)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM utilisateur u
                    WHERE u.id_utilisateur = p_utilisateur
                      AND u.actif AND u.coach_actif) THEN
        PERFORM refus_coach('coach_inactif', 'Le coach n''est pas activé pour ce compte');
    END IF;
END $$;

COMMENT ON FUNCTION exiger_coach(INTEGER) IS
    'COA-1 : toute fonction du coach refuse un compte dont coach_actif est faux.';
