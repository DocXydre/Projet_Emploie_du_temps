-- -----------------------------------------------------------------------------
-- Choisir, modifier, supprimer                         (SPT-19, SPT-21, SPT-26)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION choisir_seance_sport(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ,
    p_occurrence  INTEGER DEFAULT NULL,
    p_origine     VARCHAR DEFAULT 'proposition'
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache      INTEGER;
    v_obstacle   TEXT;
    v_bloc       TSTZRANGE;
    v_jour       DATE := jour_de(p_debut);
    v_ancien     DATE;
    v_occurrence INTEGER;
BEGIN
    SELECT t.id_tache INTO v_tache FROM tache t WHERE t.code = 'SPORT' AND t.active;
    IF v_tache IS NULL THEN
        RAISE EXCEPTION 'Le sport est désactivé' USING ERRCODE = 'no_data_found';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tache_lieu tl
                    WHERE tl.id_tache = v_tache AND tl.id_lieu = p_lieu) THEN
        RAISE EXCEPTION 'Sport inconnu' USING ERRCODE = 'no_data_found';
    END IF;

    IF p_occurrence IS NOT NULL THEN
        SELECT jour_de(COALESCE(o.debut_seance, lower(o.creneau))) INTO v_ancien
          FROM occurrence o
         WHERE o.id_occurrence = p_occurrence
           AND o.id_utilisateur = p_utilisateur
           AND o.id_tache = v_tache
           AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee');
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Séance introuvable, ou déjà passée'
                  USING ERRCODE = 'no_data_found';
        END IF;
    END IF;

    v_obstacle := obstacle_seance(p_utilisateur, p_lieu, p_debut, p_occurrence, FALSE);
    IF v_obstacle IS NOT NULL THEN
        RAISE EXCEPTION '%', v_obstacle USING ERRCODE = 'check_violation';
    END IF;

    v_bloc := bloc_de_seance(p_utilisateur, p_lieu, p_debut);

    -- La réservation du jour cède la place, et ce qui est mobile se replacera.
    DELETE FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
       AND (jour_de(o.debut_seance) = v_jour OR o.creneau && v_bloc);

    UPDATE occurrence o
       SET creneau = NULL, statut = 'a_placer',
           motif = 'Déplacée par une séance de sport'
     WHERE o.id_utilisateur = p_utilisateur
       AND o.statut = 'planifiee'
       AND NOT o.epinglee
       AND NOT o.rappel_journee
       AND o.id_occurrence IS DISTINCT FROM p_occurrence
       AND o.creneau && v_bloc;

    IF p_occurrence IS NULL THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                                origine, epinglee, id_lieu, debut_seance, motif)
        VALUES (v_tache, p_utilisateur,
                tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                          GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
                v_bloc, 'planifiee', 'manuelle', TRUE, p_lieu, p_debut, 'Choisie')
        RETURNING id_occurrence INTO v_occurrence;

        INSERT INTO choix_sport (id_utilisateur, id_occurrence, id_lieu, jour_semaine,
                                 heure, semaine, origine)
        VALUES (p_utilisateur, v_occurrence, p_lieu,
                EXTRACT(ISODOW FROM v_jour)::SMALLINT,
                (p_debut AT TIME ZONE 'Europe/Paris')::TIME,
                lundi_de(v_jour), p_origine);
    ELSE
        v_occurrence := p_occurrence;

        UPDATE occurrence o
           SET creneau      = v_bloc,
               fenetre      = tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                                        GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
               id_lieu      = p_lieu,
               debut_seance = p_debut,
               -- Déplacée à aujourd'hui, elle compte comme annoncée : la
               -- relance du soir doit la voir.
               statut       = CASE WHEN v_jour = jour_de(now()) THEN 'notifiee'
                                   ELSE 'planifiee' END,
               epinglee     = TRUE,
               motif        = 'Modifiée'
         WHERE o.id_occurrence = v_occurrence;

        -- SPT-22 : le choix suit la séance. L'habitude d'origine n'est pas
        -- touchée : elle perd seulement cette semaine-ci.
        INSERT INTO choix_sport (id_utilisateur, id_occurrence, id_lieu, jour_semaine,
                                 heure, semaine, origine)
        VALUES (p_utilisateur, v_occurrence, p_lieu,
                EXTRACT(ISODOW FROM v_jour)::SMALLINT,
                (p_debut AT TIME ZONE 'Europe/Paris')::TIME,
                lundi_de(v_jour), 'modifiee')
        ON CONFLICT (id_occurrence) DO UPDATE
           SET id_lieu      = EXCLUDED.id_lieu,
               jour_semaine = EXCLUDED.jour_semaine,
               heure        = EXCLUDED.heure,
               semaine      = EXCLUDED.semaine,
               origine      = 'modifiee',
               date_choix   = now();
    END IF;

    PERFORM organiser_sport_semaine(p_utilisateur, lundi_de(v_jour));
    IF v_ancien IS NOT NULL AND lundi_de(v_ancien) <> lundi_de(v_jour) THEN
        PERFORM organiser_sport_semaine(p_utilisateur, lundi_de(v_ancien));
    END IF;

    -- SPT-22 : le choix a déplacé les habitudes. Les autres semaines ouvertes
    -- reprennent leurs réservations sur les propositions du moment.
    PERFORM organiser_sport_semaine(p_utilisateur, lundi_de(jour_de(now())) + 7 * i, TRUE)
       FROM generate_series(0, 2) i
      WHERE lundi_de(jour_de(now())) + 7 * i NOT IN (lundi_de(v_jour),
                                                    COALESCE(lundi_de(v_ancien), lundi_de(v_jour)));

    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION choisir_seance_sport IS
    'Crée une séance choisie, ou modifie celle donnée : sport, jour, heure. Le
     choix est retenu pour les habitudes, la réservation du jour disparaît, et
     la semaine est recomplétée (SPT-19, SPT-21, SPT-22).';
