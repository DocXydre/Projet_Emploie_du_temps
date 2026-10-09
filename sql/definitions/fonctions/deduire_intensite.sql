-- -----------------------------------------------------------------------------
-- L'intensité et les groupes d'une séance libre, d'après ce qui a été fait
--                                                                     (LIB-12)
--
-- D'abord la note d'effort : dure à 7, modérée de 4 à 6, légère en dessous. À
-- défaut la séance de la montre, par la fréquence cardiaque moyenne rapportée
-- à la fréquence maximale connue. À défaut, dure, par prudence. C'est ce que
-- la règle des séances dures compare pour les séances qui suivent (SEC-3).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION deduire_intensite(p_occurrence INTEGER)
RETURNS VARCHAR LANGUAGE plpgsql AS $$
DECLARE
    s           RECORD;
    v_effort    INTEGER;
    v_fc        INTEGER;
    v_fc_max    INTEGER;
    v_intensite VARCHAR;
    v_groupes   TEXT[];
BEGIN
    SELECT se.discipline, se.libre, o.id_utilisateur INTO s
      FROM seance se JOIN occurrence o ON o.id_occurrence = se.id_occurrence
     WHERE se.id_occurrence = p_occurrence;
    IF NOT FOUND OR NOT s.libre THEN
        RETURN NULL;
    END IF;

    SELECT b.effort INTO v_effort FROM bilan_seance b WHERE b.id_occurrence = p_occurrence;
    SELECT max(a.fc_moyenne) INTO v_fc
      FROM activite_sante a WHERE a.id_occurrence = p_occurrence;

    IF v_effort IS NOT NULL THEN
        v_intensite := CASE WHEN v_effort >= 7 THEN 'dure'
                            WHEN v_effort >= 4 THEN 'moderee'
                            ELSE 'legere' END;
    ELSIF v_fc IS NOT NULL THEN
        -- La fréquence maximale connue : la plus haute que la montre ait vue,
        -- à défaut l'estimation par l'âge.
        SELECT GREATEST(
                   (SELECT max(a.fc_max) FROM activite_sante a
                     WHERE a.id_utilisateur = s.id_utilisateur),
                   (SELECT 220 - EXTRACT(YEAR FROM age(p.date_naissance))::INTEGER
                      FROM profil p WHERE p.id_utilisateur = s.id_utilisateur))
          INTO v_fc_max;
        v_intensite := CASE WHEN v_fc_max IS NULL THEN 'dure'
                            WHEN v_fc >= 0.80 * v_fc_max THEN 'dure'
                            WHEN v_fc >= 0.65 * v_fc_max THEN 'moderee'
                            ELSE 'legere' END;
    ELSE
        v_intensite := 'dure';
    END IF;

    IF s.discipline = 'musculation' THEN
        SELECT COALESCE(array_agg(DISTINCT e.groupe_principal), '{}') INTO v_groupes
          FROM serie_saisie ss JOIN exercice e ON e.id_exercice = ss.id_exercice
         WHERE ss.id_occurrence = p_occurrence;
    ELSE
        v_groupes := ARRAY['cardio'];
    END IF;

    UPDATE seance se SET intensite = v_intensite, groupes = v_groupes
     WHERE se.id_occurrence = p_occurrence;
    RETURN v_intensite;
END $$;

COMMENT ON FUNCTION deduire_intensite(INTEGER) IS
    'LIB-12 : déduit l''intensité d''une séance libre de la note d''effort, à
     défaut de la montre, à défaut la tient pour dure. Ses groupes sont ceux
     des exercices saisis.';
