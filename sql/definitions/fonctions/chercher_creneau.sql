-- -----------------------------------------------------------------------------
-- Recherche d'un créneau horaire, pour une tâche à heure imposée         (PLA-2)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chercher_creneau(
    p_utilisateur INTEGER,
    p_fenetre     TSTZRANGE,
    p_duree       INTERVAL,
    p_heure_min   TIME,
    p_heure_max   TIME,
    p_machine     BOOLEAN,
    p_commun      BOOLEAN DEFAULT FALSE
) RETURNS TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour    DATE;
    v_dernier DATE;
    v_plage   TSTZRANGE;
    v_dispo   TSTZRANGE;
BEGIN
    v_jour    := GREATEST(jour_de(lower(p_fenetre)), jour_de(now()));
    v_dernier := jour_de(upper(p_fenetre) - INTERVAL '1 second');

    WHILE v_jour <= v_dernier LOOP
        -- ABS-1 : ni machine ni ménage un jour où l'on n'est pas là.
        IF NOT est_absent(p_utilisateur, v_jour)
           AND NOT (p_machine AND machine_occupee(v_jour)) THEN

            -- Plage autorisée ce jour-là, ramenée à la fenêtre d'échéance et
            -- à ce qui reste à venir : on ne propose pas 14h quand il est 16h.
            v_plage := tstzrange(
                           (v_jour + p_heure_min) AT TIME ZONE 'Europe/Paris',
                           (v_jour + p_heure_max) AT TIME ZONE 'Europe/Paris',
                           '[)')
                       * p_fenetre
                       * tstzrange(now(), NULL, '[)');

            IF NOT isempty(v_plage) THEN
                FOR v_dispo IN
                    SELECT d FROM disponibilites_pour(p_utilisateur, p_commun,
                                                      lower(v_plage), upper(v_plage)) d
                     ORDER BY lower(d)
                LOOP
                    IF upper(v_dispo) - lower(v_dispo) >= p_duree THEN
                        RETURN tstzrange(lower(v_dispo), lower(v_dispo) + p_duree, '[)');
                    END IF;
                END LOOP;
            END IF;
        END IF;

        v_jour := v_jour + 1;
    END LOOP;

    RETURN NULL;
END $$;
