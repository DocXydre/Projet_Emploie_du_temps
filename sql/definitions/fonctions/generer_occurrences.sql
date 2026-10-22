-- -----------------------------------------------------------------------------
-- Génération des occurrences manquantes                          (opération 2)
--
-- Une tâche qui a déjà une occurrence en cours est ignorée : c'est ce qui
-- empêche l'accumulation.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generer_occurrences(p_horizon_jours INTEGER DEFAULT 35)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    -- Garde-fou contre une boucle trop longue. Les horizons utilisés en
    -- pratique restent bien en dessous.
    ITERATIONS_MAX CONSTANT INTEGER := 60;

    t         RECORD;
    v_curseur TIMESTAMPTZ;
    v_fenetre TSTZRANGE;
    v_limite  TIMESTAMPTZ;
    v_tours   INTEGER;
    v_creees  INTEGER := 0;
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

            IF v_curseur IS NULL THEN
                -- Jamais faite : elle est due dès aujourd'hui.
                v_fenetre := fenetre_pour(
                    t.rappel_journee, now(),
                    now() + make_interval(days => t.periodicite_max_jours));

                INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine)
                VALUES (t.id_tache, t.id_utilisateur_defaut, v_fenetre, 'recurrence');

                v_creees  := v_creees + 1;
                v_curseur := upper(v_fenetre);
            END IF;
        END IF;

        -- Prolonger la chaîne jusqu'à l'horizon. Ces occurrences sont des
        -- prévisions : elles seront effacées et refaites dès qu'une validation
        -- réelle donnera une meilleure référence.
        v_tours := 0;
        WHILE v_curseur < v_limite AND v_tours < ITERATIONS_MAX LOOP
            v_fenetre := fenetre_pour(
                t.rappel_journee,
                v_curseur + make_interval(days => t.periodicite_min_jours),
                v_curseur + make_interval(days => t.periodicite_max_jours));

            INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine)
            VALUES (t.id_tache, t.id_utilisateur_defaut, v_fenetre, 'recurrence');

            v_creees  := v_creees + 1;
            v_curseur := upper(v_fenetre);
            v_tours   := v_tours + 1;
        END LOOP;
    END LOOP;

    RETURN v_creees;
END $$;
