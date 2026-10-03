-- -----------------------------------------------------------------------------
-- Un jour où le mode allégé joue                                       (PLA-16)
--
-- Ces jours-là, la répartition est volontairement inégale. Ils ne comptent
-- donc pas dans la balance : sans cela, celui qui a pris le relais paraîtrait
-- débordé, et l'autre rattraperait la semaine suivante ce qu'il avait
-- justement demandé à ne pas faire.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION jour_allege(p_jour DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM utilisateur u
                    WHERE u.actif AND est_allege(u.id_utilisateur, p_jour));
$$;

COMMENT ON FUNCTION jour_allege(DATE) IS
    'PLA-16 : vrai si le mode allégé joue pour quelqu''un ce jour-là.';
