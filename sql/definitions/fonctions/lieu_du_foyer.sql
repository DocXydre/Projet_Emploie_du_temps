-- -----------------------------------------------------------------------------
-- Le lieu du foyer d'un compte                                         (ADR-2)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lieu_du_foyer(p_utilisateur INTEGER)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT l.id_lieu_connu
      FROM lieu_connu l JOIN utilisateur u ON u.id_foyer = l.id_foyer
     WHERE u.id_utilisateur = p_utilisateur AND l.nature = 'foyer';
$$;

COMMENT ON FUNCTION lieu_du_foyer(INTEGER) IS
    'ADR-2 : le lieu connu de nature foyer du foyer du compte, s''il a une adresse.';
