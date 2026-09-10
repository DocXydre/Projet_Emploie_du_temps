-- rejouable : ce fichier ne contient que des CREATE OR REPLACE.
-- =============================================================================
-- 019 : une tâche fixée retombe sur qui reste                     (ABS-2, ABS-3)
--
-- Le pliage du linge revient à Lorette. Jusqu'ici cette assignation valait même
-- pendant ses absences : la tâche restait à son nom, et ABS-1 refusant de poser
-- quoi que ce soit sur un jour d'absence, elle n'était plus jamais placée. Le
-- linge attendait le retour.
--
-- L'assignation fixée dit qui s'en charge d'ordinaire, pas qui s'en charge
-- quand l'autre est seul dans l'appartement.
--
-- L'appartement vide ne change pas : personne n'est présent, `choisir_assigne`
-- rend NULL, et les tâches restent en attente.
-- =============================================================================

CREATE OR REPLACE FUNCTION present_dans(p_utilisateur INTEGER, p_fenetre TSTZRANGE)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour    DATE;
    v_dernier DATE;
BEGIN
    v_jour    := GREATEST(jour_de(lower(p_fenetre)), jour_de(now()));
    v_dernier := jour_de(upper(p_fenetre) - INTERVAL '1 second');

    WHILE v_jour <= v_dernier LOOP
        IF NOT est_absent(p_utilisateur, v_jour) THEN
            RETURN TRUE;
        END IF;
        v_jour := v_jour + 1;
    END LOOP;

    RETURN FALSE;
END $$;

COMMENT ON FUNCTION present_dans IS
    'Vrai si la personne est là au moins un jour de la fenêtre. Un seul jour
     suffit : la tâche se fera ce jour-là.';


CREATE OR REPLACE FUNCTION choisir_assigne(p_tache INTEGER, p_fenetre TSTZRANGE)
RETURNS INTEGER LANGUAGE plpgsql STABLE AS $$
DECLARE
    t            RECORD;
    u            RECORD;
    v_charge     INTEGER;
    v_meilleur   INTEGER := NULL;
    v_charge_min INTEGER := NULL;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = p_tache;

    -- ABS-2 : l'assignation fixée tient tant que la personne est là.
    IF t.id_utilisateur_defaut IS NOT NULL
       AND present_dans(t.id_utilisateur_defaut, p_fenetre) THEN
        RETURN t.id_utilisateur_defaut;
    END IF;

    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif ORDER BY id_utilisateur LOOP
        CONTINUE WHEN NOT present_dans(u.id_utilisateur, p_fenetre);

        -- PLA-10 : seules les tâches domestiques entrent dans la balance de
        -- répartition. Le sport est personnel et n'est pas compté.
        SELECT COALESCE(sum(t2.duree_minutes), 0) INTO v_charge
          FROM occurrence o
          JOIN tache t2 ON t2.id_tache = o.id_tache
         WHERE o.id_utilisateur = u.id_utilisateur
           AND t2.categorie <> 'sport'
           AND o.statut IN ('a_placer', 'planifiee', 'notifiee');

        IF v_charge_min IS NULL OR v_charge < v_charge_min THEN
            v_meilleur   := u.id_utilisateur;
            v_charge_min := v_charge;
        END IF;
    END LOOP;

    RETURN v_meilleur;   -- NULL si l'appartement est vide toute la fenêtre
END $$;
