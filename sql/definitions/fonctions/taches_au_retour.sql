-- -----------------------------------------------------------------------------
-- Ce qu'on refait en rentrant                                           (ABS-8)
--
-- Deux jours sans personne, et l'eau de Sassy a stagné : on la change en
-- rentrant, quel que soit le jour où elle l'avait été. C'est une occurrence en
-- plus, comme celles d'avant le départ, et elle revient au premier rentré.
--
-- Les prévisions de la même tâche qui tombaient pendant l'absence n'ont plus de
-- sens : personne n'était là pour les faire. Elles sont retirées, et la chaîne
-- repart du retour.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION taches_au_retour(p_horizon_jours INTEGER DEFAULT 35)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    f         TSTZRANGE;
    t         RECORD;
    v_retour  TIMESTAMPTZ;
    v_jour    DATE;
    v_premier INTEGER;
    v_creees  INTEGER := 0;
BEGIN
    -- Un retour qui a bougé laisse une occurrence qui ne veut plus rien dire.
    DELETE FROM occurrence o
     WHERE o.origine = 'retour'
       AND o.statut IN ('a_placer', 'planifiee')
       AND lower(o.fenetre) > now()
       AND NOT EXISTS (SELECT 1 FROM notification n WHERE n.id_occurrence = o.id_occurrence)
       AND NOT EXISTS (
           SELECT 1
             FROM absences_communes(now() - INTERVAL '60 days',
                                    now() + make_interval(days => p_horizon_jours)) g
            WHERE NOT upper_inf(g)
              AND jour_de(lower(o.fenetre)) - jour_de(upper(g)) IN (0, 1));

    FOR f IN SELECT g FROM absences_communes(now() - INTERVAL '60 days',
                                             now() + make_interval(days => p_horizon_jours)) g
    LOOP
        -- Un départ sans date de retour n'a pas de retour à préparer.
        CONTINUE WHEN upper_inf(f);
        v_retour := upper(f);
        CONTINUE WHEN v_retour <= now()
                   OR v_retour > now() + make_interval(days => p_horizon_jours);

        -- Rentré tard le soir, on s'en occupe le lendemain.
        v_jour := jour_de(v_retour)
                  + ((v_retour AT TIME ZONE 'Europe/Paris')::TIME >= TIME '21:00')::INTEGER;

        -- Le premier rentré, s'il n'y en a qu'un. Rentrés ensemble, le
        -- placement choisit comme pour n'importe quelle tâche.
        SELECT CASE WHEN count(*) = 1 THEN min(a.id_utilisateur) END INTO v_premier
          FROM absence a
          JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur AND u.actif
         WHERE upper(a.periode) = v_retour;

        FOR t IN SELECT * FROM tache
                  WHERE active AND rappel_journee AND au_retour_apres_jours IS NOT NULL
                  ORDER BY priorite
        LOOP
            CONTINUE WHEN v_retour - lower(f) <= make_interval(days => t.au_retour_apres_jours);

            CONTINUE WHEN EXISTS (
                SELECT 1 FROM occurrence o
                 WHERE o.id_tache = t.id_tache
                   AND o.origine = 'retour'
                   AND o.statut <> 'abandonnee'
                   AND o.fenetre && tstzrange(debut_jour(v_jour), debut_jour(v_jour + 1), '[)'));

            -- TAC-19 : la fontaine lavée ce jour-là vaut eau changée.
            CONTINUE WHEN EXISTS (
                SELECT 1 FROM remplacement r
                  JOIN occurrence o ON o.id_tache = r.id_tache_faite
                 WHERE r.id_tache_couverte = t.id_tache
                   AND o.statut IN ('planifiee', 'notifiee')
                   AND o.creneau IS NOT NULL
                   AND jour_de(lower(o.creneau)) = v_jour);

            DELETE FROM occurrence o
             WHERE o.id_tache = t.id_tache
               AND o.origine = 'recurrence'
               AND o.statut IN ('a_placer', 'planifiee')
               AND NOT o.epinglee
               AND lower(o.fenetre) >= debut_jour(jour_de(lower(f)))
               AND NOT EXISTS (SELECT 1 FROM notification n
                                WHERE n.id_occurrence = o.id_occurrence);

            INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine, motif)
            VALUES (t.id_tache, v_premier,
                    tstzrange(debut_jour(v_jour), debut_jour(v_jour + 1), '[)'),
                    'retour',
                    format('Au retour : l''appartement est resté vide depuis le %s',
                           to_char(lower(f) AT TIME ZONE 'Europe/Paris', 'DD/MM')));

            v_creees := v_creees + 1;
        END LOOP;
    END LOOP;

    RETURN v_creees;
END $$;

COMMENT ON FUNCTION taches_au_retour(INTEGER) IS
    'ABS-8 : pose, le jour du retour, les tâches à refaire quand l''appartement
     est resté vide plus longtemps que leur seuil. Appelée par le placement,
     avant la génération des occurrences.';
