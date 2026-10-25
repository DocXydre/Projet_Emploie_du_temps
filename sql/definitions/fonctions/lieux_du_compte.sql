-- -----------------------------------------------------------------------------
-- Les lieux connus d'un compte                                   (ADR-1, POS-5)
--
-- Les siens, et ceux de son foyer. Jamais les lieux personnels d'un autre.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lieux_du_compte(p_utilisateur INTEGER)
RETURNS SETOF lieu_connu LANGUAGE sql STABLE AS $$
    SELECT l.*
      FROM lieu_connu l
     WHERE l.id_utilisateur = p_utilisateur
        OR l.id_foyer = (SELECT id_foyer FROM utilisateur WHERE id_utilisateur = p_utilisateur)
     ORDER BY l.id_lieu_connu;
$$;

COMMENT ON FUNCTION lieux_du_compte(INTEGER) IS
    'ADR-1, POS-5 : les lieux personnels du compte et les lieux communs de son foyer.';
