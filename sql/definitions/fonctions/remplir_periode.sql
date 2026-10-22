-- -----------------------------------------------------------------------------
-- Remplir une période d'une tâche à rythme                              (CND-4)
--
-- N fois dans la période : ce qui y est déjà fait ou prévu compte, et ce qui
-- manque se répartit en parts égales sur les jours qui restent. Une occurrence
-- faite compte pour la période où elle est faite. Rend le nombre créé.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION remplir_periode(p_tache INTEGER, p_nombre INTEGER, p_periode DATERANGE)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    t        tache%ROWTYPE;
    v_debut  DATE := GREATEST(lower(p_periode), jour_de(now()));
    v_fin    DATE := upper(p_periode);
    v_deja   INTEGER;
    v_manque INTEGER;
    v_jours  INTEGER;
    v_de     DATE;
    v_a      DATE;
BEGIN
    IF v_debut >= v_fin THEN
        RETURN 0;
    END IF;
    SELECT * INTO t FROM tache WHERE id_tache = p_tache;

    SELECT count(*) INTO v_deja
      FROM occurrence
     WHERE id_tache = p_tache
       AND ((statut = 'faite' AND p_periode @> jour_de(date_faite))
            OR (statut IN ('a_placer', 'planifiee', 'notifiee')
                AND p_periode @> jour_de(lower(fenetre))));

    v_jours  := v_fin - v_debut;
    -- Sept fois par semaine, à deux jours de la fin : on n'en fait que deux.
    v_manque := LEAST(p_nombre - v_deja, v_jours);
    IF v_manque <= 0 THEN
        RETURN 0;
    END IF;

    FOR k IN 0 .. v_manque - 1 LOOP
        v_de := v_debut + (k * v_jours) / v_manque;
        v_a  := v_debut + ((k + 1) * v_jours) / v_manque;
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine)
        VALUES (p_tache, t.id_utilisateur_defaut,
                tstzrange(debut_jour(v_de), debut_jour(v_a), '[)'),
                'recurrence');
    END LOOP;

    RETURN v_manque;
END $$;

COMMENT ON FUNCTION remplir_periode(INTEGER, INTEGER, DATERANGE) IS
    'CND-4 : complète jusqu''à N les occurrences d''une période, réparties sur les jours qui restent.';
