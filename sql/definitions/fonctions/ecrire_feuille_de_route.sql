CREATE OR REPLACE FUNCTION ecrire_feuille_de_route(p_utilisateur INTEGER, p_texte TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_objectif INTEGER;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    UPDATE objectif o SET feuille_de_route = p_texte
     WHERE o.id_utilisateur = p_utilisateur AND o.principal AND o.statut = 'actif'
    RETURNING o.id_objectif INTO v_objectif;
    IF v_objectif IS NULL THEN
        PERFORM refus_coach('objectif_requis',
            'La feuille de route s''écrit sur l''objectif principal actif, et il n''y en a pas');
    END IF;
    RETURN v_objectif;
END $$;

COMMENT ON FUNCTION ecrire_feuille_de_route(INTEGER, TEXT) IS
    'OBJ-11, OBJ-12 : écrit ou révise le chemin jusqu''à l''échéance, sur
     l''objectif principal actif du compte et lui seul.';
