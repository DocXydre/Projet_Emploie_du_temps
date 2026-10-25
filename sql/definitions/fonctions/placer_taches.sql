-- -----------------------------------------------------------------------------
-- Le placement enchaîne les trois                         (opération 4, WKD-3)
--
-- Le placement prépare, pose, puis rapproche. Avant la boucle : les
-- occurrences manquantes et les propositions. Après elle : ce qu'une autre
-- tâche couvre, et ce qui va ensemble. Ce que les descriptions demandent de
-- plus (avant un départ, au retour), c'est HAL qui le pose (VER-10).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION placer_taches(p_horizon_jours integer DEFAULT 35, p_stabilite_jours integer DEFAULT 7)
 RETURNS integer
 LANGUAGE plpgsql
AS $$
DECLARE
    o         RECORD;
    v_creneau TSTZRANGE;
    v_duree   INTERVAL;
    v_places  INTEGER := 0;
    v_gele    TIMESTAMPTZ;
    v_assigne INTEGER;
    v_lieu    INTEGER;
    -- VER-3 : où étaient les occurrences des tâches décrites avant ce placement.
    v_avant   JSONB;
BEGIN
    PERFORM generer_occurrences(p_horizon_jours);

    -- WKD-3 : une absence vaut réponse à une proposition de week-end. Sans cet
    -- appel, la proposition restait au calendrier alors que le billet était
    -- acheté et l'absence déclarée.
    PERFORM entretenir_propositions();

    -- PLA-5, PLA-6 : un créneau notifié, épinglé, ou prévu dans les prochains jours
    -- ne bouge plus. Un planning qui change tous les matins ne sert à rien :
    -- on ne peut pas s'organiser autour de quelque chose qui se dérobe.
    v_gele := now() + make_interval(days => p_stabilite_jours);

    SELECT COALESCE(jsonb_object_agg(av.id_occurrence, COALESCE(av.creneau::TEXT, '')), '{}')
      INTO v_avant
      FROM occurrence av
     WHERE av.statut IN ('a_placer', 'planifiee', 'notifiee')
       AND EXISTS (SELECT 1 FROM description_tache d WHERE d.id_tache = av.id_tache)
       AND tache_decrite(av.id_tache);

    -- VER-2 : ce que HAL a épinglé un jour où la personne n'est pas là redevient
    -- au moteur, qui le replace ; HAL le relira.
    UPDATE occurrence
       SET epinglee = FALSE
     WHERE epinglee_par = 'hal'
       AND statut = 'planifiee'
       AND creneau IS NOT NULL
       AND id_utilisateur IS NOT NULL
       AND est_absent(id_utilisateur, jour_de(lower(creneau)));

    -- ABS-5 : exception au gel, quand la personne est absente ce jour-là.
    -- Sans elle, un départ déclaré pour le week-end prochain ne déplacerait
    -- aucune tâche, puisqu'il tombe dans la période gelée.
    UPDATE occurrence
       SET creneau = NULL, statut = 'a_placer', motif = NULL
     WHERE statut = 'planifiee'
       AND NOT epinglee
       -- PLN-4 : une séance proposée par HAL occupe son créneau. Elle
       -- n'est pas épinglée, mais seul HAL ou l'utilisateur la déplace.
       AND origine <> 'coach'
       AND (creneau IS NULL
            OR lower(creneau) > v_gele
            OR (id_utilisateur IS NOT NULL
                AND est_absent(id_utilisateur, jour_de(lower(creneau)))));

    -- TAC-19 : une première fois avant d'attribuer quoi que ce soit, pour que
    -- le ramassage retiré ne compte pas dans le tour de celui qui l'aurait eu.
    PERFORM absorber_les_couvertes();

    FOR o IN
        SELECT oc.id_occurrence, oc.id_tache, oc.id_utilisateur, oc.fenetre,
               oc.rappel_journee,
               t.duree_minutes, t.heure_min, t.heure_max, t.libelle
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut = 'a_placer'
           -- Le sport ne passe pas par ici : HAL propose les séances, ou
           -- l'utilisateur les pose (SPT-33).
           AND t.id_type_tache IS NOT NULL
           AND upper(oc.fenetre) > now()
           AND lower(oc.fenetre) < now() + make_interval(days => p_horizon_jours)
         ORDER BY t.priorite, upper(oc.fenetre), t.duree_minutes DESC
    LOOP
        -- ABS-2 : l'assigné se décide au placement, en fonction de qui est là.
        v_assigne := COALESCE(o.id_utilisateur, choisir_assigne(o.id_tache, o.fenetre));

        IF v_assigne IS NULL THEN
            -- ABS-4 : personne dans l'appartement sur toute la fenêtre. On ne
            -- salit pas ce qu'on n'habite pas : la tâche attend le retour.
            UPDATE occurrence
               SET id_utilisateur = NULL,
                   motif = 'Personne dans l''appartement sur cette période'
             WHERE id_occurrence = o.id_occurrence;
            CONTINUE;
        END IF;

        IF v_assigne IS DISTINCT FROM o.id_utilisateur THEN
            UPDATE occurrence SET id_utilisateur = v_assigne
             WHERE id_occurrence = o.id_occurrence;
        END IF;

        v_duree := make_interval(mins => o.duree_minutes);
        v_lieu := NULL;

        IF o.rappel_journee THEN
            v_creneau := chercher_jour(v_assigne, o.fenetre, v_duree);
        ELSE
            v_creneau := chercher_creneau(v_assigne, o.fenetre, v_duree,
                                          o.heure_min, o.heure_max);
        END IF;

        -- PLA-8 : une occurrence non plaçable n'est jamais supprimée. Elle garde
        -- son statut et reçoit un motif lisible.
        IF v_creneau IS NULL THEN
            UPDATE occurrence
               SET motif = format('Aucune place de %s min avant le %s',
                                  o.duree_minutes,
                                  to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
             WHERE id_occurrence = o.id_occurrence;
        ELSE
            UPDATE occurrence
               SET creneau = v_creneau,
                   statut  = 'planifiee',
                   id_lieu = v_lieu,
                   motif   = CASE
                                 WHEN v_lieu IS NOT NULL THEN
                                     format('%s le %s, trajet compris',
                                            (SELECT libelle FROM lieu_sport
                                              WHERE id_lieu = v_lieu),
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM à HH24hMI'))
                                 WHEN o.rappel_journee THEN
                                     format('À faire le %s',
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                                 ELSE
                                     format('Placée le %s',
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM à HH24hMI'))
                             END
             WHERE id_occurrence = o.id_occurrence;

            v_places := v_places + 1;
        END IF;
    END LOOP;

    -- TAC-19 : le vidage vaut ramassage. Une occurrence que couvre une autre
    -- tâche prévue le même jour n'a rien à faire au planning.
    PERFORM absorber_les_couvertes();

    -- TAC-15, TAC-16 : ce qui va ensemble se fait le même jour. Après le
    -- placement, puisqu'il faut savoir où tombe la tâche qui mène.
    PERFORM poser_les_accompagnements();

    -- VER-3 : ce que ce placement a créé, déplacé ou laissé à placer, pour une
    -- tâche décrite, entre dans la file. Ce qui n'a pas bougé n'y entre pas, ni
    -- ce qui tombe au-delà des sept jours qui viennent : le moteur repose ces
    -- prévisions chaque matin, et la vérification de la semaine les relit
    -- toutes (VER-5). Sans cette borne, chaque placement ferait appeler HAL.
    PERFORM noter_verification(o2.id_occurrence, NULL,
                               CASE WHEN COALESCE(v_avant ->> o2.id_occurrence::TEXT, '') = ''
                                         AND o2.creneau IS NOT NULL THEN 'creee'
                                    WHEN o2.creneau IS NULL THEN 'a_placer'
                                    ELSE 'deplacee' END)
       FROM occurrence o2
      WHERE o2.statut IN ('a_placer', 'planifiee', 'notifiee')
        AND upper(o2.fenetre) > now()
        AND lower(COALESCE(o2.creneau, o2.fenetre)) < v_gele
        AND tache_decrite(o2.id_tache)
        AND (NOT (v_avant ? o2.id_occurrence::TEXT)
             OR (v_avant ->> o2.id_occurrence::TEXT) IS DISTINCT FROM COALESCE(o2.creneau::TEXT, ''));

    RETURN v_places;
END $$;
