CREATE OR REPLACE FUNCTION noter(
    p_utilisateur INTEGER,
    p_categorie   VARCHAR,
    p_texte       TEXT,
    p_source      VARCHAR DEFAULT 'deduction',
    p_confirmee   BOOLEAN DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_note INTEGER;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    -- CAR-4 : soixante notes actives, pas une de plus.
    IF (SELECT count(*) FROM note_coach n WHERE n.id_utilisateur = p_utilisateur) >= 60 THEN
        PERFORM refus_coach('carnet_plein',
            'Le carnet compte déjà soixante notes : fusionne ou retire avant d''en ajouter');
    END IF;
    IF char_length(COALESCE(p_texte, '')) > 300 THEN
        PERFORM refus_coach('requete_invalide',
                            'Une note du carnet tient en 300 caractères');
    END IF;

    INSERT INTO note_coach (id_utilisateur, categorie, texte, source, confirmee)
    VALUES (p_utilisateur, p_categorie, btrim(p_texte), p_source,
            COALESCE(p_confirmee, p_source = 'utilisateur'))
    RETURNING id_note INTO v_note;
    RETURN v_note;
END $$;

COMMENT ON FUNCTION noter(INTEGER, VARCHAR, TEXT, VARCHAR, BOOLEAN) IS
    'CAR-1, CAR-4 : écrit une note courte au carnet. Refuse la soixante et
     unième.';
