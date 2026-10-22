-- -----------------------------------------------------------------------------
-- Recherche d'un jour, pour un rappel sans heure imposée            (PLA-3, PLA-4)
--
-- On cherche une journée assez libre, pas un créneau précis.
--
-- Et le jour le moins chargé de la fenêtre, pas le premier venu : prendre le
-- premier entassait toutes les tâches sur la même journée.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chercher_jour(
    p_utilisateur INTEGER,
    p_fenetre     TSTZRANGE,
    p_duree       INTERVAL
) RETURNS TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    -- Au-delà, l'examen de chaque jour coûte plus qu'il ne rapporte : une tâche
    -- mensuelle n'a pas besoin d'être comparée sur trente et un jours.
    EXAMEN_MAX CONSTANT INTEGER := 21;

    v_jour       DATE;
    v_dernier    DATE;
    v_deja       INTEGER;
    v_libre      INTERVAL;
    v_meilleur   DATE     := NULL;
    v_charge_min INTEGER  := NULL;
    v_libre_max  INTERVAL := NULL;
BEGIN
    v_jour    := GREATEST(jour_de(lower(p_fenetre)), jour_de(now()));
    v_dernier := LEAST(jour_de(upper(p_fenetre) - INTERVAL '1 second'),
                       v_jour + EXAMEN_MAX);

    WHILE v_jour <= v_dernier LOOP
        -- ABS-1 : un jour d'absence ne reçoit rien. On ne fait pas le ménage
        -- d'un appartement où l'on n'est pas.
        IF est_absent(p_utilisateur, v_jour) THEN
            v_jour := v_jour + 1;
            CONTINUE;
        END IF;

        SELECT COALESCE(sum(t.duree_minutes), 0) INTO v_deja
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = p_utilisateur
           AND o.rappel_journee
           AND o.creneau IS NOT NULL
           AND o.statut IN ('planifiee', 'notifiee')
           AND jour_de(lower(o.creneau)) = v_jour;

        v_libre := temps_libre_jour(p_utilisateur, v_jour) - make_interval(mins => v_deja);

        -- Deux critères, dans cet ordre : d'abord le moins de tâches déjà
        -- posées, ensuite le plus de temps libre. Le second départage les
        -- journées vides de tâches mais déjà très occupées.
        IF v_libre >= p_duree
           AND (v_charge_min IS NULL
                OR v_deja < v_charge_min
                OR (v_deja = v_charge_min AND v_libre > v_libre_max)) THEN
            v_meilleur   := v_jour;
            v_charge_min := v_deja;
            v_libre_max  := v_libre;
        END IF;

        v_jour := v_jour + 1;
    END LOOP;

    IF v_meilleur IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN tstzrange(debut_jour(v_meilleur), debut_jour(v_meilleur + 1), '[)');
END $$;
