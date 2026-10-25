-- -----------------------------------------------------------------------------
-- Une tâche a-t-elle une description ?                                  (MTA-1)
--
-- Sa dernière version n'est pas vide. C'est ce qui la fait relire par HAL
-- (VER-3, VER-5).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tache_decrite(p_tache INTEGER) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT d.texte <> ''
                       FROM description_tache d
                      WHERE d.id_tache = p_tache
                      ORDER BY d.id_description_tache DESC
                      LIMIT 1), FALSE);
$$;

COMMENT ON FUNCTION tache_decrite(INTEGER) IS
    'MTA-1 : vrai si la dernière version de la description de la tâche n''est pas vide.';
