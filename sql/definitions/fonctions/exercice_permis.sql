-- -----------------------------------------------------------------------------
-- Un exercice que ce compte peut faire                                  (EXO-11)
--
-- Actif, et du catalogue commun ou ajouté par ce compte : l'exercice que
-- l'autre a ajouté pour lui ne se saisit pas et ne se propose pas ici.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION exercice_permis(p_exercice INTEGER, p_utilisateur INTEGER)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM exercice e
                    WHERE e.id_exercice = p_exercice AND e.actif
                      AND (e.id_utilisateur IS NULL OR e.id_utilisateur = p_utilisateur));
$$;

COMMENT ON FUNCTION exercice_permis(INTEGER, INTEGER) IS
    'EXO-11 : vrai si l''exercice est actif et du catalogue commun ou ajouté
     par ce compte.';
