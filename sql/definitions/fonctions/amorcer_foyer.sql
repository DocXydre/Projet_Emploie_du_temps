-- -----------------------------------------------------------------------------
-- Le premier foyer                                               (FOY-1, FOY-12)
--
-- Tant qu'aucun foyer n'est ouvert, les comptes actifs en forment un. Son
-- administrateur est celui du serveur, à défaut le plus ancien compte. Rien du
-- passé ne change : tâches, occurrences et journal gardent leurs numéros.
--
-- Sans effet dès qu'un foyer existe : un membre retiré ne revient pas tout seul.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION amorcer_foyer()
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_admin INTEGER;
    v_foyer INTEGER;
BEGIN
    IF EXISTS (SELECT 1 FROM foyer WHERE ferme_le IS NULL) THEN
        RETURN NULL;
    END IF;

    SELECT id_utilisateur INTO v_admin
      FROM utilisateur
     WHERE actif
     ORDER BY (role = 'admin') DESC, id_utilisateur
     LIMIT 1;
    IF v_admin IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO foyer (id_administrateur) VALUES (v_admin) RETURNING id_foyer INTO v_foyer;
    UPDATE utilisateur SET id_foyer = v_foyer WHERE actif AND id_foyer IS NULL;
    RETURN v_foyer;
END $$;

COMMENT ON FUNCTION amorcer_foyer() IS
    'FOY-12 : réunit les comptes actifs en un premier foyer, s''il n''y en a aucun.';
