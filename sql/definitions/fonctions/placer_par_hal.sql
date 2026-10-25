-- -----------------------------------------------------------------------------
-- HAL place une occurrence selon la description de sa tâche     (VER-1, VER-10)
--
-- Il la déplace à un jour, et à une heure pour une tâche à heure imposée, ou il
-- en pose une de plus que le rythme quand la description le demande : les
-- poubelles avant un départ. Dans les deux cas, elle est épinglée par HAL, avec
-- son motif, et le moteur ne la déplace plus (PLA-5). Celui à qui elle revient
-- est prévenu, avec la raison (VER-6).
--
-- Ce que la main a épinglé ne bouge pas (VER-2), ni ce qui est fait. Le reste
-- de la base veille comme pour tout placement : un créneau qui en chevauche un
-- autre est refusé (TAC-6).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION placer_par_hal(
    p_occurrence INTEGER,
    p_tache      INTEGER,
    p_jour       DATE,
    p_heure      TIME,
    p_pour       INTEGER,
    p_motif      TEXT
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o          occurrence%ROWTYPE;
    t          tache%ROWTYPE;
    v_creneau  TSTZRANGE;
    v_pour     INTEGER;
    v_motif    TEXT := btrim(COALESCE(p_motif, ''));
    v_id       INTEGER := p_occurrence;
BEGIN
    IF p_occurrence IS NOT NULL THEN
        SELECT * INTO o FROM occurrence WHERE id_occurrence = p_occurrence;
        IF NOT FOUND THEN
            PERFORM refus_coach('introuvable', 'Cette occurrence n''existe pas');
        END IF;
        IF o.statut NOT IN ('a_placer', 'planifiee', 'notifiee') THEN
            PERFORM refus_coach('deja_close', 'Cette occurrence est faite ou close : elle ne bouge plus');
        END IF;
        IF o.epinglee_par = 'admin' THEN
            PERFORM refus_coach('placee_a_la_main',
                'Elle a été placée à la main : celui qui l''a mise là a le dernier mot (VER-2)');
        END IF;
    END IF;

    SELECT * INTO t FROM tache WHERE id_tache = COALESCE(o.id_tache, p_tache);
    IF NOT FOUND OR t.id_type_tache IS NULL OR NOT t.active THEN
        PERFORM refus_coach('introuvable', 'Cette tâche n''existe pas, ou elle est arrêtée');
    END IF;
    IF length(v_motif) < 3 THEN
        PERFORM refus_coach('requete_invalide', 'Le motif dit pourquoi ce jour-là, en une phrase');
    END IF;
    IF p_jour IS NULL OR p_jour < jour_de(now()) THEN
        PERFORM refus_coach('requete_invalide', 'Le jour est passé');
    END IF;

    v_pour := COALESCE(p_pour, o.id_utilisateur, t.id_utilisateur_defaut,
                       choisir_assigne(t.id_tache, tstzrange(debut_jour(p_jour),
                                                             debut_jour(p_jour + 1), '[)')));
    IF v_pour IS NOT NULL AND est_absent(v_pour, p_jour) THEN
        PERFORM refus_coach('absent', 'Cette personne n''est pas là ce jour-là (ABS-2)');
    END IF;

    IF t.rappel_journee THEN
        v_creneau := tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)');
    ELSE
        IF p_heure IS NULL THEN
            PERFORM refus_coach('requete_invalide',
                format('« %s » a une heure : donne celle du début, entre %s et %s',
                       t.libelle, to_char(t.heure_min, 'HH24hMI'), to_char(t.heure_max, 'HH24hMI')));
        END IF;
        IF p_heure < t.heure_min OR p_heure + make_interval(mins => t.duree_minutes) > t.heure_max THEN
            PERFORM refus_coach('hors_plage',
                format('« %s » se fait entre %s et %s', t.libelle,
                       to_char(t.heure_min, 'HH24hMI'), to_char(t.heure_max, 'HH24hMI')));
        END IF;
        v_creneau := tstzrange((p_jour + p_heure) AT TIME ZONE 'Europe/Paris',
                               (p_jour + p_heure) AT TIME ZONE 'Europe/Paris'
                                   + make_interval(mins => t.duree_minutes), '[)');
        IF lower(v_creneau) < now() THEN
            PERFORM refus_coach('requete_invalide', 'Cette heure est déjà passée');
        END IF;
    END IF;

    -- VER-3 : ce que HAL fait lui-même ne revient pas dans la file.
    PERFORM set_config('planif.par_hal', '1', TRUE);
    BEGIN
        IF p_occurrence IS NULL THEN
            INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut, origine,
                                    epinglee, epinglee_par, motif)
            VALUES (t.id_tache, v_pour,
                    tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)'),
                    v_creneau, 'planifiee', 'hal', TRUE, 'hal', v_motif)
            RETURNING id_occurrence INTO v_id;
        ELSE
            UPDATE occurrence
               SET fenetre        = range_merge(fenetre, tstzrange(debut_jour(p_jour),
                                                                   debut_jour(p_jour + 1), '[)')),
                   creneau        = v_creneau,
                   id_utilisateur = v_pour,
                   statut         = CASE WHEN statut = 'notifiee' THEN 'notifiee' ELSE 'planifiee' END,
                   epinglee       = TRUE,
                   epinglee_par   = 'hal',
                   motif          = v_motif
             WHERE id_occurrence = p_occurrence;
        END IF;
    EXCEPTION WHEN exclusion_violation THEN
        PERFORM set_config('planif.par_hal', '', TRUE);
        PERFORM refus_coach('creneau_pris', 'Ce créneau en chevauche un autre de cette personne');
    END;
    PERFORM set_config('planif.par_hal', '', TRUE);

    -- Ce que HAL a placé n'attend plus d'être relu.
    UPDATE verification_tache SET traitee_le = now()
     WHERE id_occurrence = v_id AND traitee_le IS NULL;

    -- VER-6 : la raison, en une phrase, à celui à qui elle revient.
    -- Le nom de la tâche une fois, que HAL l'ait mis dans son motif ou non.
    IF v_pour IS NOT NULL THEN
        INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
        VALUES (v_pour, v_id, 'alerte',
                CASE WHEN lower(v_motif) LIKE lower(t.libelle) || '%' THEN v_motif
                     ELSE format('%s : %s', t.libelle, v_motif) END);
    END IF;

    RETURN v_id;
END $$;

COMMENT ON FUNCTION placer_par_hal(INTEGER, INTEGER, DATE, TIME, INTEGER, TEXT) IS
    'VER-1, VER-10 : HAL déplace une occurrence, ou en pose une de plus, selon la description de sa tâche ; elle est épinglée par HAL et la personne prévenue.';
