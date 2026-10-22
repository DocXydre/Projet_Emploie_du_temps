-- -----------------------------------------------------------------------------
-- Le moment préféré dans la fenêtre d'un rythme                         (CND-4)
--
-- Début, milieu ou fin : le premier, le deuxième ou le dernier tiers des jours
-- de la fenêtre. Il s'essaie d'abord ; s'il ne donne rien, la fenêtre entière.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fenetre_preferee(p_fenetre TSTZRANGE, p_moment TEXT)
RETURNS TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_premier DATE := jour_de(lower(p_fenetre));
    v_dernier DATE := jour_de(upper(p_fenetre) - INTERVAL '1 second');
    v_tiers   INTEGER;
BEGIN
    v_tiers := GREATEST(1, (v_dernier - v_premier + 1) / 3);
    IF p_moment IS NULL OR p_moment = 'indifferent' OR v_dernier - v_premier < 2 THEN
        RETURN p_fenetre;
    END IF;
    RETURN p_fenetre * CASE p_moment
        WHEN 'debut' THEN tstzrange(debut_jour(v_premier), debut_jour(v_premier + v_tiers), '[)')
        WHEN 'fin'   THEN tstzrange(debut_jour(v_dernier + 1 - v_tiers), debut_jour(v_dernier + 1), '[)')
        ELSE tstzrange(debut_jour(v_premier + v_tiers), debut_jour(v_dernier + 1 - v_tiers), '[)')
    END;
END $$;

COMMENT ON FUNCTION fenetre_preferee(TSTZRANGE, TEXT) IS
    'CND-4 : le tiers de la fenêtre qui correspond au moment préféré d''un rythme.';
