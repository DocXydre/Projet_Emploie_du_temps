CREATE OR REPLACE FUNCTION ouvrir_fenetre_mesure(
    p_utilisateur INTEGER,
    p_type        VARCHAR,
    p_debut       DATE,
    p_fin         DATE,
    p_consigne    TEXT DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_fenetre INTEGER;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    IF p_fin < p_debut OR p_fin - p_debut >= 7 THEN
        PERFORM refus_coach('requete_invalide',
            'Une fenêtre de mesure dure de un à sept jours');
    END IF;
    IF p_fin < jour_de(now()) THEN
        PERFORM refus_coach('requete_invalide', 'Cette fenêtre est déjà passée');
    END IF;
    -- MES-5 : une seule fenêtre ouverte par type de mesure.
    IF EXISTS (SELECT 1 FROM fenetre_mesure f
                WHERE f.id_utilisateur = p_utilisateur
                  AND f.type_mesure = p_type AND f.statut = 'ouverte') THEN
        PERFORM refus_coach('requete_invalide',
            format('Une fenêtre est déjà ouverte pour la mesure « %s »', p_type));
    END IF;

    INSERT INTO fenetre_mesure (id_utilisateur, type_mesure, periode, consigne)
    VALUES (p_utilisateur, p_type, daterange(p_debut, p_fin, '[]'), p_consigne)
    RETURNING id_fenetre INTO v_fenetre;

    PERFORM tracer_coach(p_utilisateur, 'fenetre_mesure', v_fenetre);
    RETURN v_fenetre;
END $$;

COMMENT ON FUNCTION ouvrir_fenetre_mesure(INTEGER, VARCHAR, DATE, DATE, TEXT) IS
    'MES-1, MES-5 : ouvre une fenêtre de mesure de sept jours au plus. Une
     seule fenêtre ouverte à la fois pour un même type.';
