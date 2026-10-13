-- -----------------------------------------------------------------------------
-- Régler le foyer : son nom, les droits sur les tâches                   (FOY-6)
--
-- Un argument vide laisse le réglage tel qu'il est.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION regler_foyer(p_admin  INTEGER,
                                        p_nom    TEXT DEFAULT NULL,
                                        p_ajout  TEXT DEFAULT NULL,
                                        p_modif  TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_foyer INTEGER := exiger_admin_du_foyer(p_admin);
BEGIN
    UPDATE foyer
       SET nom          = COALESCE(NULLIF(btrim(p_nom), ''), nom),
           ajout_taches = COALESCE(p_ajout, ajout_taches),
           modif_taches = COALESCE(p_modif, modif_taches)
     WHERE id_foyer = v_foyer;
END $$;

COMMENT ON FUNCTION regler_foyer(INTEGER, TEXT, TEXT, TEXT) IS
    'FOY-6 : l''administrateur règle le nom du foyer et les droits sur les tâches.';
