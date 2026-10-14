-- -----------------------------------------------------------------------------
-- Un calendrier suivi qu'on a le droit de régler                (COL-7, FOY-9)
--
-- Les calendriers d'un foyer se lisent et se règlent à deux, comme le faisait
-- le bot : un groupe de TD, une UE écartée, un flux arrêté. Hors de son foyer,
-- on ne touche qu'aux siens. Rend le code de la source, et refuse sinon.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION calendrier_du_foyer(p_auteur INTEGER, p_id_source INTEGER)
RETURNS VARCHAR LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_source source%ROWTYPE;
BEGIN
    SELECT * INTO v_source FROM source WHERE id_source = p_id_source;
    IF NOT FOUND OR v_source.mode_collecte <> 'ics' THEN
        RAISE EXCEPTION 'Ce calendrier n''existe pas' USING ERRCODE = 'no_data_found';
    END IF;

    IF v_source.id_utilisateur IS DISTINCT FROM p_auteur
       AND (foyer_de(p_auteur) IS NULL
            OR foyer_de(v_source.id_utilisateur) IS DISTINCT FROM foyer_de(p_auteur)) THEN
        RAISE EXCEPTION 'Ce calendrier n''est pas dans ton foyer'
              USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_source.code;
END $$;

COMMENT ON FUNCTION calendrier_du_foyer(INTEGER, INTEGER) IS
    'COL-7, FOY-9 : le code d''un calendrier suivi du foyer de l''auteur ; refus sinon.';
