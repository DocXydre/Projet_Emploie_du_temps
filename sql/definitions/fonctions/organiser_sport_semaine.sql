-- -----------------------------------------------------------------------------
-- Les semaines suivent la fréquence de chacun                  (SPT-28, SPT-23)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION organiser_sport_semaine(
    p_utilisateur INTEGER,
    p_lundi       DATE,
    p_refaire     BOOLEAN DEFAULT FALSE
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache     INTEGER;
    v_minimum   INTEGER;
    v_choisies  INTEGER;
    v_reservees INTEGER;
    v_manque    INTEGER;
    v_jours     DATE[];
    v_creees    INTEGER := 0;
    p           RECORD;
BEGIN
    SELECT t.id_tache INTO v_tache
      FROM tache t WHERE t.code = 'SPORT' AND t.active;

    -- SPT-28 : le minimum est celui de la personne, pas celui de la tâche.
    v_minimum := minimum_sport(p_utilisateur);

    -- Une semaine passée ne se réorganise pas.
    IF v_tache IS NULL OR p_lundi + 7 <= jour_de(now()) THEN
        RETURN 0;
    END IF;

    -- Les réservations devenues fausses : jamais posées, ou tombées depuis un
    -- jour d'absence, un jour désormais choisi, ou sous une obligation apparue.
    DELETE FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
       AND jour_de(COALESCE(o.debut_seance, lower(o.fenetre))) BETWEEN p_lundi AND p_lundi + 6
       AND (o.creneau IS NULL
            OR (lower(o.creneau) > now()
                AND (est_absent(p_utilisateur, jour_de(o.debut_seance))
                     OR EXISTS (SELECT 1 FROM occurrence c
                                 WHERE c.id_utilisateur = p_utilisateur
                                   AND c.id_tache = v_tache
                                   AND c.origine <> 'quota'
                                   AND c.statut IN ('planifiee', 'notifiee', 'faite')
                                   AND jour_de(COALESCE(c.debut_seance, lower(c.creneau)))
                                       = jour_de(o.debut_seance))
                     OR EXISTS (SELECT 1 FROM occupation oc
                                 WHERE oc.id_utilisateur = p_utilisateur
                                   AND oc.periode && o.creneau))));

    SELECT count(*) INTO v_choisies
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine <> 'quota'
       AND o.statut IN ('planifiee', 'notifiee', 'faite')
       AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) BETWEEN p_lundi AND p_lundi + 6;

    -- Une réservation passée ne compte plus : elle attend d'être constatée
    -- (seances_a_determiner_passees), et une autre doit prendre le relais.
    SELECT count(*) INTO v_reservees
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('planifiee', 'notifiee')
       AND lower(o.creneau) > now()
       AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

    v_manque := v_minimum - v_choisies - v_reservees;

    -- Trop de réservations : une séance vient d'être choisie ailleurs. On
    -- repart des meilleures plutôt que de garder les restes. Celles déjà
    -- annoncées ce matin restent, sauf s'il le faut vraiment.
    IF (v_manque < 0 OR p_refaire) AND v_reservees > 0 THEN
        DELETE FROM occurrence o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.id_tache = v_tache
           AND o.origine = 'quota'
           AND o.statut = 'planifiee'
           AND lower(o.creneau) > now()
           AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

        SELECT count(*) INTO v_reservees
          FROM occurrence o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.id_tache = v_tache
           AND o.origine = 'quota'
           AND o.statut = 'notifiee'
           AND lower(o.creneau) > now()
           AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

        IF v_choisies + v_reservees > v_minimum THEN
            DELETE FROM occurrence o
             WHERE o.id_occurrence IN (
                   SELECT o2.id_occurrence FROM occurrence o2
                    WHERE o2.id_utilisateur = p_utilisateur
                      AND o2.id_tache = v_tache
                      AND o2.origine = 'quota'
                      AND o2.statut = 'notifiee'
                      AND lower(o2.creneau) > now()
                      AND jour_de(o2.debut_seance) BETWEEN p_lundi AND p_lundi + 6
                    ORDER BY o2.debut_seance DESC
                    LIMIT v_choisies + v_reservees - v_minimum);
            v_reservees := GREATEST(v_minimum - v_choisies, 0);
        END IF;

        v_manque := v_minimum - v_choisies - v_reservees;
    END IF;

    IF v_manque <= 0 THEN
        RETURN 0;
    END IF;

    SELECT COALESCE(array_agg(jour_de(o.debut_seance)), ARRAY[]::DATE[]) INTO v_jours
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('planifiee', 'notifiee')
       AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

    FOR p IN
        SELECT pr.*, ls.libelle AS lieu_libelle
          FROM propositions_sport(p_utilisateur, p_lundi, NULL, v_jours, v_manque) pr
          JOIN lieu_sport ls ON ls.id_lieu = pr.id_lieu
         ORDER BY pr.rang
    LOOP
        -- Ce qui était mobile dessous se replacera autour (SPT-23).
        UPDATE occurrence o
           SET creneau = NULL, statut = 'a_placer',
               motif = 'Déplacée par une réservation de sport'
         WHERE o.id_utilisateur = p_utilisateur
           AND o.statut = 'planifiee'
           AND NOT o.epinglee
           AND NOT o.rappel_journee
           AND o.origine <> 'quota'
           AND o.creneau && p.bloc;

        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                                origine, id_lieu, debut_seance, motif)
        VALUES (v_tache, p_utilisateur,
                tstzrange(LEAST(debut_jour(p.jour), lower(p.bloc)),
                          GREATEST(debut_jour(p.jour + 1), upper(p.bloc)), '[)'),
                p.bloc, 'planifiee', 'quota', p.id_lieu, p.debut,
                format('À déterminer. Proposition : %s à %s. Choisis dans /organiser.',
                       p.lieu_libelle,
                       to_char(p.debut AT TIME ZONE 'Europe/Paris', 'HH24hMI')));

        v_creees := v_creees + 1;
    END LOOP;

    RETURN v_creees;
END $$;

COMMENT ON FUNCTION organiser_sport_semaine IS
    'Complète la semaine jusqu''au minimum du compte avec des réservations à
     déterminer, sur les meilleures propositions (SPT-18, SPT-23, SPT-28).';
