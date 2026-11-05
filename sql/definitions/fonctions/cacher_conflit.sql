-- -----------------------------------------------------------------------------
-- « Voir plus tard » sur un conflit                                    (COL-23)
--
-- Le conflit est caché jusqu'à sept jours avant sa date (le début de sa période) ;
-- il revient de lui-même, v_conflit.a_arbitrer lisant cache_jusqu_a. On ne cache
-- qu'une fois : un conflit déjà caché, même revenu, ne se cache plus, et un
-- conflit à moins de sept jours ne se cache pas.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cacher_conflit(p_conflit INTEGER)
RETURNS TIMESTAMPTZ LANGUAGE plpgsql AS $$
DECLARE
    c        conflit%ROWTYPE;
    v_retour TIMESTAMPTZ;
BEGIN
    SELECT * INTO c FROM conflit WHERE id_conflit = p_conflit FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Conflit % introuvable', p_conflit
              USING ERRCODE = 'no_data_found';
    END IF;

    IF c.statut = 'caduc' THEN
        RAISE EXCEPTION 'Ce conflit n''existe plus'
              USING ERRCODE = 'check_violation';
    END IF;
    IF c.statut <> 'en_attente' THEN
        RAISE EXCEPTION 'Ce conflit est déjà réglé'
              USING ERRCODE = 'check_violation';
    END IF;
    IF c.cache_jusqu_a IS NOT NULL THEN
        RAISE EXCEPTION 'Ce conflit a déjà été mis de côté une fois : il ne se cache plus'
              USING ERRCODE = 'check_violation';
    END IF;

    v_retour := lower(c.periode) - INTERVAL '7 days';
    IF v_retour <= now() THEN
        RAISE EXCEPTION 'Ce conflit a lieu dans moins de sept jours : il ne se cache plus'
              USING ERRCODE = 'check_violation';
    END IF;

    UPDATE conflit SET cache_jusqu_a = v_retour WHERE id_conflit = p_conflit;
    RETURN v_retour;
END $$;

COMMENT ON FUNCTION cacher_conflit(INTEGER) IS
    'COL-23 : cache un conflit en attente jusqu''à sept jours avant sa date et rend la date de retour. Refuse un conflit déjà caché une fois, ou à moins de sept jours.';
