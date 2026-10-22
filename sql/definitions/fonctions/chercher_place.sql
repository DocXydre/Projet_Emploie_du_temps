-- -----------------------------------------------------------------------------
-- Chercher la place d'une occurrence                     (PLA-2, PLA-3, CND-4)
--
-- Un jour pour un rappel, un créneau pour une tâche à heure imposée, en
-- tenant compte des règles de la tâche (CND-8). Le moment préféré d'un rythme
-- s'essaie d'abord, puis la fenêtre entière.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chercher_place(p_utilisateur INTEGER,
                                          p_tache       INTEGER,
                                          p_fenetre     TSTZRANGE)
RETURNS TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    t         tache%ROWTYPE;
    f         RECORD;
    v_duree   INTERVAL;
    v_essais  TSTZRANGE[];
    v_essai   TSTZRANGE;
    v_creneau TSTZRANGE;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = p_tache;
    v_duree := make_interval(mins => t.duree_minutes);

    SELECT * INTO f FROM frequence_de(p_tache, jour_de(lower(p_fenetre)));
    v_essais := ARRAY[p_fenetre];
    IF f.rythme_nombre IS NOT NULL AND f.rythme_moment <> 'indifferent' THEN
        v_essais := ARRAY[fenetre_preferee(p_fenetre, f.rythme_moment), p_fenetre];
    END IF;

    FOREACH v_essai IN ARRAY v_essais LOOP
        CONTINUE WHEN isempty(v_essai);
        IF t.rappel_journee THEN
            v_creneau := chercher_jour(p_utilisateur, v_essai, v_duree, p_tache);
        ELSE
            v_creneau := chercher_creneau(p_utilisateur, v_essai, v_duree,
                                          t.heure_min, t.heure_max, t.utilise_machine,
                                          t.requiert_les_deux, p_tache);
        END IF;
        IF v_creneau IS NOT NULL THEN
            RETURN v_creneau;
        END IF;
    END LOOP;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION chercher_place(INTEGER, INTEGER, TSTZRANGE) IS
    'PLA-2, PLA-3, CND-4, CND-8 : le jour ou le créneau d''une occurrence, selon les règles et le moment préféré de sa tâche.';
