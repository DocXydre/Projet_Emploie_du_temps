-- -----------------------------------------------------------------------------
-- En mode allégé ce jour-là, pour de bon                               (PLA-16)
--
-- Le mode ne joue que s'il reste quelqu'un pour prendre le relais. Quand tous
-- les comptes actifs l'ont activé le même jour, il s'annule pour tout le monde
-- et la répartition redevient celle de tous les jours.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION est_allege(p_utilisateur INTEGER, p_jour DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
               SELECT 1 FROM allegement a
                WHERE a.id_utilisateur = p_utilisateur
                  AND a.periode && tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)'))
       AND EXISTS (
               SELECT 1 FROM utilisateur u
                WHERE u.actif
                  AND u.id_utilisateur <> p_utilisateur
                  AND NOT EXISTS (
                      SELECT 1 FROM allegement a
                       WHERE a.id_utilisateur = u.id_utilisateur
                         AND a.periode && tstzrange(debut_jour(p_jour),
                                                    debut_jour(p_jour + 1), '[)')));
$$;

COMMENT ON FUNCTION est_allege(INTEGER, DATE) IS
    'PLA-16 : vrai si la personne est en mode allégé ce jour-là et qu''au moins
     un autre compte actif ne l''est pas.';
