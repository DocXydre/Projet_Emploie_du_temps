CREATE OR REPLACE FUNCTION saisir_mesure(
    p_utilisateur INTEGER,
    p_type        VARCHAR,
    p_valeur      NUMERIC,
    p_unite       VARCHAR,
    p_cote        VARCHAR DEFAULT NULL,
    p_date        DATE    DEFAULT NULL,
    p_exercice    INTEGER DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_date    DATE := COALESCE(p_date, jour_de(now()));
    v_fenetre INTEGER;
    v_mesure  INTEGER;
BEGIN
    -- MES-2 : saisie pendant une fenêtre ouverte de son type, elle s'y
    -- rattache et la passe à faite. MES-4 : hors fenêtre, elle se saisit aussi.
    SELECT f.id_fenetre INTO v_fenetre
      FROM fenetre_mesure f
     WHERE f.id_utilisateur = p_utilisateur AND f.type_mesure = p_type
       AND f.statut = 'ouverte' AND f.periode @> v_date;

    INSERT INTO mesure (id_utilisateur, type_mesure, valeur, unite, cote, date_mesure,
                        id_fenetre, id_exercice)
    VALUES (p_utilisateur, p_type, p_valeur, p_unite, p_cote, v_date, v_fenetre, p_exercice)
    RETURNING id_mesure INTO v_mesure;

    -- Une mesure par côté ne ferme la fenêtre qu'une fois les deux côtés saisis.
    IF v_fenetre IS NOT NULL
       AND (p_cote IS NULL
            OR (SELECT count(DISTINCT m.cote) FROM mesure m
                 WHERE m.id_fenetre = v_fenetre) >= 2) THEN
        UPDATE fenetre_mesure f SET statut = 'faite' WHERE f.id_fenetre = v_fenetre;
    END IF;
    RETURN v_mesure;
END $$;

COMMENT ON FUNCTION saisir_mesure IS
    'MES-2, MES-4 : enregistre une mesure, par côté s''il y a lieu. Pendant une
     fenêtre ouverte de son type, elle s''y rattache et la clôt.';
