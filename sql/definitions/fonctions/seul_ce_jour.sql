-- -----------------------------------------------------------------------------
-- Seul dans l'appartement ce jour-là                                   (PLA-15)
--
-- Vrai quand tous les autres comptes actifs sont absents la journée entière.
-- Ce qu'on fait ces jours-là ne compte ni dans la balance ni dans le tour :
-- on ne rattrape pas au retour ce que l'autre a fait parce qu'il vivait là.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seul_ce_jour(p_utilisateur INTEGER, p_jour DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM utilisateur u
                    WHERE u.actif AND u.id_utilisateur <> p_utilisateur)
       AND NOT EXISTS (
           SELECT 1 FROM utilisateur u
            WHERE u.actif
              AND u.id_utilisateur <> p_utilisateur
              AND NOT EXISTS (
                  SELECT 1 FROM absence a
                   WHERE a.id_utilisateur = u.id_utilisateur
                     AND a.periode @> tstzrange(debut_jour(p_jour),
                                                debut_jour(p_jour + 1), '[)')));
$$;

COMMENT ON FUNCTION seul_ce_jour(INTEGER, DATE) IS
    'PLA-15 : vrai si tous les autres comptes actifs sont absents ce jour-là.';
