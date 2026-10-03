-- -----------------------------------------------------------------------------
-- Ce que l'autre en sait                                               (SPT-32)
--
-- Une séance sait si quelqu'un a dit qu'il venait : l'écran le montre, et
-- c'est tout ce dont il a besoin.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION compagnons_de_seance(p_occurrence INTEGER)
RETURNS TABLE (nom TEXT, statut TEXT)
LANGUAGE sql STABLE AS $$
    SELECT u.nom::TEXT, inv.statut::TEXT
      FROM invitation_sport inv
      JOIN utilisateur u ON u.id_utilisateur = inv.id_invite
     WHERE inv.id_occurrence = p_occurrence
     ORDER BY u.nom;
$$;

COMMENT ON FUNCTION compagnons_de_seance IS
    'Qui a été invité sur cette séance, et ce qu''il a répondu (SPT-32).';
