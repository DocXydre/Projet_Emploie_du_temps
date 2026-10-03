-- -----------------------------------------------------------------------------
-- Qui d'autre pourrait venir                                           (SPT-30)
--
-- Tous les autres comptes actifs. À deux dans l'appartement cela fait une
-- personne, mais rien dans le modèle n'oblige à rester deux.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION partenaires_sport(p_utilisateur INTEGER)
RETURNS SETOF INTEGER LANGUAGE sql STABLE AS $$
    SELECT u.id_utilisateur
      FROM utilisateur u
     WHERE u.actif
       AND u.id_utilisateur <> p_utilisateur
     ORDER BY u.id_utilisateur;
$$;

COMMENT ON FUNCTION partenaires_sport IS
    'Les autres comptes actifs, ceux à qui une séance peut être proposée à
     deux (SPT-30).';
