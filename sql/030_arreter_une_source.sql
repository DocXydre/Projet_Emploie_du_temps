-- rejouable : ce fichier ne contient qu'un CREATE OR REPLACE.
-- -----------------------------------------------------------------------------
-- 030 — Arrêter de suivre un emploi du temps                           (COL-21)
--
-- Une démission, un semestre qui se termine, un calendrier qu'on ne veut plus
-- voir. La source cesse d'être collectée, ce qu'elle annonçait pour la suite
-- disparaît du planning, et ce qu'elle a été reste : l'historique doit pouvoir
-- dire ce qu'on faisait il y a six mois à telle date.
--
-- Ce n'est pas une migration qui arrête une source précise. Arrêter le planning
-- McDonald's est une donnée, comme en donner l'URL : ça se fait depuis le bot
-- (/arreter MCDO), et le schéma se contente de savoir le faire proprement.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION arreter_source(p_code VARCHAR) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_source   RECORD;
    v_retirees INTEGER;
BEGIN
    SELECT * INTO v_source FROM source WHERE code = upper(p_code);
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- L'URL est gardée : reprendre la source ne demandera que /lien. Une
    -- source inactive n'est ni collectée, ni signalée en panne dans le bilan
    -- du matin.
    UPDATE source SET active = FALSE WHERE id_source = v_source.id_source;

    -- COL-21 : seul l'avenir disparaît. Un service en cours a lieu, il reste.
    DELETE FROM occupation
     WHERE id_source = v_source.id_source
       AND lower(periode) > now();
    GET DIAGNOSTICS v_retirees = ROW_COUNT;

    RETURN jsonb_build_object('source',               v_source.code,
                              'occupations_retirees', v_retirees);
END $$;

COMMENT ON FUNCTION arreter_source IS
    'Cesse de suivre une source : elle n''est plus collectée, ses occupations à
     venir sont retirées, les passées restent (COL-21).';
