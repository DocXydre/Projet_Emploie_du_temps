-- -----------------------------------------------------------------------------
-- Tout le monde fait du sport                                          (SPT-29)
--
-- Chaque compte actif a ses trois semaines. Celui qui n'en veut pas met sa
-- fréquence à zéro : il garde ses écrans et peut choisir une séance à la main,
-- mais rien ne lui est réservé.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sportifs() RETURNS SETOF INTEGER
LANGUAGE sql STABLE AS $$
    SELECT u.id_utilisateur
      FROM utilisateur u
     WHERE u.actif
     ORDER BY u.id_utilisateur;
$$;

COMMENT ON FUNCTION sportifs() IS
    'Tous les comptes actifs : le sport est personnel, chacun a ses semaines
     et sa fréquence (SPT-29).';
