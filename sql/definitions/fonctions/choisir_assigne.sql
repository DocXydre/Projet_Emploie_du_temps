-- -----------------------------------------------------------------------------
-- À qui revient la prochaine                                           (PLA-12)
--
-- Le tour d'abord, la balance ensuite. On donne la tâche à qui ne l'a pas eue
-- la dernière fois, sauf si cela creuse l'écart de charge au-delà d'une heure :
-- une alternance aveugle donnerait tout le ménage d'une semaine à celui qui est
-- déjà pris, au motif que c'était son tour.
--
-- Une heure de tolérance, parce que les tâches durent de dix à quarante-cinq
-- minutes : en dessous, le moindre écart casserait l'alternance et l'on
-- reviendrait au défaut qu'on corrige.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION choisir_assigne(p_tache INTEGER, p_fenetre TSTZRANGE)
RETURNS INTEGER LANGUAGE plpgsql STABLE AS $$
DECLARE
    TOLERANCE_MINUTES CONSTANT INTEGER := 60;

    t              RECORD;
    u              RECORD;
    v_dernier      INTEGER;
    v_charge       INTEGER;
    v_moins_charge INTEGER := NULL;
    v_charge_min   INTEGER := NULL;
    v_tour         INTEGER := NULL;
    v_charge_tour  INTEGER := NULL;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = p_tache;

    -- ABS-2 : l'assignation fixée tient tant que la personne est là. Le pliage
    -- du linge revient à Lorette, et le roulement ne la remplace pas.
    IF t.id_utilisateur_defaut IS NOT NULL
       AND present_dans(t.id_utilisateur_defaut, p_fenetre) THEN
        RETURN t.id_utilisateur_defaut;
    END IF;

    v_dernier := dernier_a_faire(p_tache);

    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif ORDER BY id_utilisateur LOOP
        CONTINUE WHEN NOT present_dans(u.id_utilisateur, p_fenetre);

        v_charge := charge_domestique(u.id_utilisateur);

        IF v_charge_min IS NULL OR v_charge < v_charge_min THEN
            v_moins_charge := u.id_utilisateur;
            v_charge_min   := v_charge;
        END IF;

        IF u.id_utilisateur IS DISTINCT FROM v_dernier
           AND (v_charge_tour IS NULL OR v_charge < v_charge_tour) THEN
            v_tour        := u.id_utilisateur;
            v_charge_tour := v_charge;
        END IF;
    END LOOP;

    IF v_tour IS NOT NULL
       AND v_charge_tour <= COALESCE(v_charge_min, 0) + TOLERANCE_MINUTES THEN
        RETURN v_tour;
    END IF;

    RETURN v_moins_charge;   -- NULL si l'appartement est vide toute la fenêtre
END $$;

COMMENT ON FUNCTION choisir_assigne IS
    'Le tour de celui qui ne l''a pas eue la dernière fois, tant que l''écart de
     charge reste inférieur à une heure ; sinon le moins chargé (PLA-12).';
