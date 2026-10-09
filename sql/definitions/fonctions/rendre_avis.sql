CREATE OR REPLACE FUNCTION rendre_avis(p_utilisateur INTEGER, p_objectif INTEGER,
                                       p_avis VARCHAR, p_detail TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    UPDATE objectif o SET avis = p_avis, avis_detail = p_detail
     WHERE o.id_objectif = p_objectif AND o.id_utilisateur = p_utilisateur
       AND o.statut IN ('actif', 'en_pause');
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Objectif introuvable, ou déjà clos');
    END IF;

    PERFORM tracer_coach(p_utilisateur, 'avis_objectif', p_objectif);
    RETURN p_objectif;
END $$;

COMMENT ON FUNCTION rendre_avis(INTEGER, INTEGER, VARCHAR, TEXT) IS
    'OBJ-5 : enregistre l''avis du coach sur un objectif. L''avis ne bloque
     rien : l''utilisateur garde son objectif s''il le veut.';
