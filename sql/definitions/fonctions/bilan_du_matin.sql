-- -----------------------------------------------------------------------------
-- Le bilan du matin montre la journée entière                         (NOT-4)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bilan_du_matin() RETURNS INTEGER
LANGUAGE sql AS $$
    -- Le bilan de tous les comptes, d'un coup : la route d'administration et
    -- les tests. L'ordonnanceur, lui, sert chacun à son heure (NOT-15).
    SELECT COALESCE(sum(bilan_du_matin_de(id_utilisateur)), 0)::INTEGER
      FROM (SELECT id_utilisateur FROM utilisateur WHERE actif ORDER BY id_utilisateur) u
$$;

COMMENT ON FUNCTION bilan_du_matin() IS
    'NOT-4 : le bilan du matin de tous les comptes actifs, d''un coup.';
