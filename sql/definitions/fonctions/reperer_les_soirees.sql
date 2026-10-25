-- -----------------------------------------------------------------------------
-- Les soirées probables de la nuit                                     (SOI-1)
--
-- À minuit, un compte dont la position est sue, qui n'est ni au foyer, ni dans
-- un lieu de séjour, ni dans un train retenu, est noté en soirée probable pour
-- la nuit qui commence, c'est-à-dire la veille du jour qui s'ouvre. Rejouable :
-- un compte déjà noté ne l'est pas deux fois.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reperer_les_soirees(p_minuit TIMESTAMPTZ DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_minuit TIMESTAMPTZ := COALESCE(p_minuit, debut_jour(jour_de(now())));
    v_nuit   DATE := jour_de(v_minuit) - 1;
    v_nombre INTEGER;
BEGIN
    INSERT INTO soiree (id_utilisateur, nuit, origine)
    SELECT u.id_utilisateur, v_nuit, 'position'
      FROM utilisateur u
      CROSS JOIN LATERAL (SELECT * FROM presence_a(u.id_utilisateur, v_minuit)) pr
      LEFT JOIN lieu_connu l ON l.id_lieu_connu = pr.id_lieu_connu
     WHERE u.actif AND u.coach_actif AND pr.id_presence IS NOT NULL
       AND (l.id_lieu_connu IS NULL OR l.nature NOT IN ('foyer', 'sejour'))
       AND NOT EXISTS (SELECT 1 FROM trajet t
                        WHERE t.id_utilisateur = u.id_utilisateur AND t.statut = 'retenue'
                          AND t.periode @> v_minuit)
    ON CONFLICT (id_utilisateur, nuit) DO NOTHING;
    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION reperer_les_soirees(TIMESTAMPTZ) IS
    'SOI-1 : note une soirée probable pour qui n''est, à minuit, ni au foyer, ni dans un lieu de séjour, ni dans un train.';
