-- -----------------------------------------------------------------------------
-- L'importance d'un échange, d'après ce que son opération a écrit      (MEM-8)
--
--   3  un objectif jugé, un plan construit, un ajustement déposé, ou ce que le
--      coach a lui-même marqué important
--   2  un signalement, une révision, des séances proposées ou retirées, une
--      fenêtre de mesure
--   1  le reste : un bilan simple, une question sans suite
--
-- Un rapport de séance n'a pas le poids d'un changement d'objectif : c'est ce
-- qui décide de ce qu'un résumé garde et de ce qu'il peut laisser tomber.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION importance_operation(p_operation TEXT, p_moment TEXT)
RETURNS SMALLINT LANGUAGE sql STABLE AS $$
    SELECT GREATEST(
        CASE WHEN p_moment IN ('signalement', 'revision', 'plan', 'faisabilite')
             THEN 2 ELSE 1 END,
        COALESCE((SELECT max(CASE
                      WHEN t.type IN ('important', 'plan', 'avis_objectif', 'ajustement')
                          THEN 3
                      WHEN t.type IN ('seance_proposee', 'seance_retiree', 'fenetre_mesure',
                                      'avis_seance_libre')
                          THEN 2
                      ELSE 1 END)
                    FROM trace_coach t WHERE t.operation = p_operation), 1)
    )::SMALLINT;
$$;

COMMENT ON FUNCTION importance_operation(TEXT, TEXT) IS
    'MEM-8 : l''importance d''un échange, de 1 à 3, lue dans la trace de ce que
     son opération a réellement écrit.';
