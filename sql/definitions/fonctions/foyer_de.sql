-- -----------------------------------------------------------------------------
-- Le foyer ouvert d'un compte, ou rien                                   (FOY-1)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION foyer_de(p_utilisateur INTEGER)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT f.id_foyer
      FROM utilisateur u
      JOIN foyer f ON f.id_foyer = u.id_foyer AND f.ferme_le IS NULL
     WHERE u.id_utilisateur = p_utilisateur
$$;

COMMENT ON FUNCTION foyer_de(INTEGER) IS
    'FOY-1 : le foyer ouvert du compte, ou NULL.';
