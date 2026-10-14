-- -----------------------------------------------------------------------------
-- Ouvrir une fenêtre de mesure                                  (MES-1, MES-5, MES-6)
--
-- Un test de course ou de force n'est pas une mesure à part : c'est une séance
-- du plan, de type test (MES-6). Sa fenêtre se rattache à elle et prend son
-- jour : sans quoi l'appli annonçait un test le samedi alors que la séance de
-- test était le vendredi. Sans séance de test autour, la fenêtre est refusée :
-- HAL propose d'abord la séance.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ouvrir_fenetre_mesure(
    p_utilisateur INTEGER,
    p_type        VARCHAR,
    p_debut       DATE,
    p_fin         DATE,
    p_consigne    TEXT DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_fenetre INTEGER;
    v_debut   DATE := p_debut;
    v_fin     DATE := p_fin;
    v_test    RECORD;
    v_seance  INTEGER;
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

    IF p_type IN ('test_course', 'test_force') THEN
        -- La séance de test la plus proche de la période demandée, à venir.
        SELECT s.id_occurrence, s.jour INTO v_test
          FROM v_seance_coach s
         WHERE s.id_utilisateur = p_utilisateur
           AND s.est_test
           AND s.statut_occurrence IN ('planifiee', 'notifiee')
           AND s.jour >= jour_de(now())
           AND s.jour BETWEEN p_debut - 7 AND p_fin + 7
           AND (s.discipline IS NULL
                OR (p_type = 'test_course' AND s.discipline IN ('course', 'cardio'))
                OR (p_type = 'test_force' AND s.discipline = 'musculation'))
         ORDER BY CASE WHEN s.jour BETWEEN p_debut AND p_fin THEN 0 ELSE 1 END,
                  abs(s.jour - p_debut), s.jour
         LIMIT 1;
        IF NOT FOUND THEN
            PERFORM refus_coach('requete_invalide',
                'Un test est une séance du plan, de type test (MES-6) : propose '
                'd''abord la séance de test, la fenêtre se rattachera à elle');
        END IF;
        -- Le jour de la séance, et le lendemain si elle est décalée d'un jour.
        v_debut := v_test.jour;
        v_fin   := v_test.jour + 1;
        v_seance := v_test.id_occurrence;
    END IF;

    INSERT INTO fenetre_mesure (id_utilisateur, type_mesure, periode, consigne, id_occurrence)
    VALUES (p_utilisateur, p_type, daterange(v_debut, v_fin, '[]'), p_consigne,
            v_seance)
    RETURNING id_fenetre INTO v_fenetre;

    PERFORM tracer_coach(p_utilisateur, 'fenetre_mesure', v_fenetre);
    RETURN v_fenetre;
END $$;

COMMENT ON FUNCTION ouvrir_fenetre_mesure(INTEGER, VARCHAR, DATE, DATE, TEXT) IS
    'MES-1, MES-5, MES-6 : ouvre une fenêtre de mesure de sept jours au plus, une
     seule ouverte par type. Celle d''un test se rattache à la séance de test et
     prend son jour.';
