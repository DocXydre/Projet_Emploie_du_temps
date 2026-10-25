-- -----------------------------------------------------------------------------
-- Sait-on où est le compte ?                                            (POS-6)
--
-- L'autorisation « Toujours » est donnée, et l'appli a écrit depuis moins de
-- 48 heures. Sans cela, aucune question de présence ne part.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION position_sue(p_utilisateur INTEGER,
                                        p_instant TIMESTAMPTZ DEFAULT now())
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT p.autorisation = 'toujours' AND p.ecrit_le > p_instant - INTERVAL '48 hours'
               AND EXISTS (SELECT 1 FROM presence pr WHERE pr.id_utilisateur = p_utilisateur)
          FROM position_actuelle p WHERE p.id_utilisateur = p_utilisateur), FALSE);
$$;

COMMENT ON FUNCTION position_sue(INTEGER, TIMESTAMPTZ) IS
    'POS-6 : l''autorisation Toujours est donnée et l''appli a écrit depuis moins de 48 heures.';
