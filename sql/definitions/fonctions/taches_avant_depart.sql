-- -----------------------------------------------------------------------------
-- Poser ce qui doit être fait avant de partir                          (TAC-12)
--
-- Une occurrence par tâche et par départ, dont la fenêtre se termine à l'heure
-- du train. Le placement ordinaire la case ensuite, en respectant les heures de
-- la tâche : le dernier soir possible pour les poubelles, la journée du départ
-- pour la litière.
--
-- TAC-18 : ces occurrences viennent en plus du roulement, même si la tâche a
-- été faite deux jours plus tôt. Elles reviennent au dernier à partir, celui
-- qui ferme l'appartement. Partis ensemble, le placement les répartit.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION taches_avant_depart(p_horizon_jours INTEGER DEFAULT 35)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    f        TSTZRANGE;
    t        RECORD;
    v_depart TIMESTAMPTZ;
    v_heure  TIME;
    v_jour   DATE;
    v_debut  TIMESTAMPTZ;
    v_dernier INTEGER;
    v_creees INTEGER := 0;
BEGIN
    -- Un départ qui a bougé laisse une occurrence qui ne veut plus rien dire.
    DELETE FROM occurrence o
     WHERE o.origine = 'depart'
       AND o.statut IN ('a_placer', 'planifiee')
       AND upper(o.fenetre) > now()
       AND NOT EXISTS (SELECT 1 FROM fenetres_appartement_vide(p_horizon_jours) g
                        WHERE o.fenetre && tstzrange(lower(g) - INTERVAL '24 hours',
                                                     lower(g), '[)'));

    FOR f IN SELECT * FROM fenetres_appartement_vide(p_horizon_jours) LOOP
        v_depart := lower(f);
        CONTINUE WHEN v_depart <= now();

        -- Celui dont l'absence commence à l'instant où l'appartement se vide.
        SELECT CASE WHEN count(*) = 1 THEN min(a.id_utilisateur) END INTO v_dernier
          FROM absence a
          JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur AND u.actif
         WHERE lower(a.periode) = v_depart;

        FOR t IN SELECT * FROM tache WHERE active AND avant_depart ORDER BY priorite LOOP

            -- Déjà faite ou déjà prévue dans la journée qui précède : le sac
            -- est sorti, on n'en redemande pas un second.
            CONTINUE WHEN EXISTS (
                SELECT 1 FROM occurrence o
                 WHERE o.id_tache = t.id_tache
                   AND ((o.statut = 'faite'
                         AND o.date_faite > v_depart - INTERVAL '20 hours')
                     OR (o.statut IN ('planifiee', 'notifiee')
                         AND o.creneau IS NOT NULL
                         AND lower(o.creneau) > v_depart - INTERVAL '20 hours'
                         AND lower(o.creneau) <= v_depart)
                     OR (o.origine = 'depart'
                         AND o.statut <> 'abandonnee'
                         AND o.fenetre && tstzrange(v_depart - INTERVAL '24 hours',
                                                    v_depart, '[)'))));

            v_heure := (v_depart AT TIME ZONE 'Europe/Paris')::TIME;

            IF t.rappel_journee THEN
                -- Un départ à l'aube ne laisse pas le temps de faire quoi que
                -- ce soit : c'est la veille.
                v_jour  := jour_de(v_depart) - (v_heure < TIME '09:00')::INTEGER;
                v_debut := debut_jour(v_jour);
            ELSE
                -- Le dernier soir possible : celui du départ s'il part assez
                -- tard pour que la tâche y tienne, sinon la veille.
                v_jour  := jour_de(v_depart)
                           - (v_heure < t.heure_min
                                        + make_interval(mins => t.duree_minutes))::INTEGER;
                v_debut := (v_jour + t.heure_min) AT TIME ZONE 'Europe/Paris';
            END IF;

            CONTINUE WHEN v_debut >= v_depart;

            -- TAC-5 : un rappel de journée se pose sur la journée entière, et
            -- sa fenêtre doit pouvoir la contenir. Elle déborde donc l'heure du
            -- train, mais le motif, lui, dit bien avant quoi.
            INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine, motif)
            VALUES (t.id_tache,
                    -- Une tâche réservée à quelqu'un le reste.
                    COALESCE(t.id_utilisateur_defaut, v_dernier),
                    fenetre_pour(t.rappel_journee, v_debut,
                                 v_depart - INTERVAL '1 second'),
                    'depart',
                    format('Avant de partir le %s : l''appartement sera vide',
                           to_char(v_depart AT TIME ZONE 'Europe/Paris',
                                   'DD/MM à HH24hMI')));

            v_creees := v_creees + 1;
        END LOOP;
    END LOOP;

    RETURN v_creees;
END $$;

COMMENT ON FUNCTION taches_avant_depart IS
    'Crée, avant chaque départ qui vide l''appartement, une occurrence des
     tâches qui ne peuvent pas attendre le retour, pour le dernier à partir
     (TAC-12, TAC-18).';
