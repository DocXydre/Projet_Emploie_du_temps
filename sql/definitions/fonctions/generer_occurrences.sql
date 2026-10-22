-- -----------------------------------------------------------------------------
-- Génération des occurrences manquantes                          (opération 2)
--
-- Une tâche qui a déjà une occurrence en cours est ignorée : c'est ce qui
-- empêche l'accumulation.
--
-- CND-4 : une tâche à rythme, N fois par semaine ou par mois, remplit chaque
-- période jusqu'à N, en comptant ce qui y est déjà fait ou prévu, et répartit
-- ce qui manque sur les jours qui restent. CND-7 : la fréquence se lit au jour
-- où l'on en est, pour qu'une règle « l'été, tous les deux jours » prenne la
-- main pendant sa période, et la rende ensuite.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generer_occurrences(p_horizon_jours INTEGER DEFAULT 35)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    -- Garde-fou contre une boucle trop longue. Les horizons utilisés en
    -- pratique restent bien en dessous.
    ITERATIONS_MAX CONSTANT INTEGER := 60;

    t          RECORD;
    f          RECORD;
    v_curseur  TIMESTAMPTZ;
    v_fenetre  TSTZRANGE;
    v_limite   TIMESTAMPTZ;
    v_tours    INTEGER;
    v_creees   INTEGER := 0;
    v_premiere BOOLEAN;
    v_periode  DATERANGE;
BEGIN
    v_limite := now() + make_interval(days => p_horizon_jours);

    -- TAC-8 : on ne génère que les tâches récurrentes. Les autres, comme
    -- « étendre le linge », sont créées par enchaînement après une lessive.
    FOR t IN SELECT * FROM tache WHERE active AND recurrente ORDER BY priorite LOOP

        -- Où en est cette tâche ? Trois cas, du plus précis au plus flou.
        SELECT max(upper(fenetre)) INTO v_curseur
          FROM occurrence
         WHERE id_tache = t.id_tache
           AND statut IN ('a_placer', 'planifiee', 'notifiee');

        IF v_curseur IS NULL THEN
            -- EXE-1 : la référence est la dernière exécution réelle, jamais la
            -- date théorique. Une tâche faite en retard ne décale pas tout.
            SELECT max(date_faite) INTO v_curseur
              FROM occurrence
             WHERE id_tache = t.id_tache AND statut = 'faite';
        END IF;

        -- Jamais faite : elle est due dès aujourd'hui.
        v_premiere := v_curseur IS NULL;
        v_curseur := COALESCE(v_curseur, now());

        -- Prolonger la chaîne jusqu'à l'horizon. Ces occurrences sont des
        -- prévisions : elles seront effacées et refaites dès qu'une validation
        -- réelle donnera une meilleure référence.
        v_tours := 0;
        WHILE v_curseur < v_limite AND v_tours < ITERATIONS_MAX LOOP
            SELECT * INTO f FROM frequence_de(t.id_tache, jour_de(GREATEST(v_curseur, now())));

            IF f.rythme_nombre IS NOT NULL THEN
                v_periode := periode_de(f.rythme_periode, jour_de(GREATEST(v_curseur, now())));
                v_creees := v_creees + remplir_periode(t.id_tache, f.rythme_nombre, v_periode);
                v_curseur := debut_jour(upper(v_periode));
            ELSE
                v_fenetre := CASE WHEN v_premiere THEN
                                 fenetre_pour(t.rappel_journee, now(),
                                              now() + make_interval(days => f.periodicite_max_jours))
                             ELSE
                                 fenetre_pour(t.rappel_journee,
                                              v_curseur + make_interval(days => f.periodicite_min_jours),
                                              v_curseur + make_interval(days => f.periodicite_max_jours))
                             END;

                INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine)
                VALUES (t.id_tache, t.id_utilisateur_defaut, v_fenetre, 'recurrence');

                v_creees  := v_creees + 1;
                v_curseur := upper(v_fenetre);
            END IF;

            v_premiere := FALSE;
            v_tours    := v_tours + 1;
        END LOOP;
    END LOOP;

    RETURN v_creees;
END $$;
