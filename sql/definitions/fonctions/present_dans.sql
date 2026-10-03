CREATE OR REPLACE FUNCTION present_dans(p_utilisateur INTEGER, p_fenetre TSTZRANGE)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour    DATE;
    v_dernier DATE;
BEGIN
    v_jour    := GREATEST(jour_de(lower(p_fenetre)), jour_de(now()));
    v_dernier := jour_de(upper(p_fenetre) - INTERVAL '1 second');

    WHILE v_jour <= v_dernier LOOP
        IF NOT est_absent(p_utilisateur, v_jour) THEN
            RETURN TRUE;
        END IF;
        v_jour := v_jour + 1;
    END LOOP;

    RETURN FALSE;
END $$;

COMMENT ON FUNCTION present_dans IS
    'Vrai si la personne est là au moins un jour de la fenêtre. Un seul jour
     suffit : la tâche se fera ce jour-là.';
