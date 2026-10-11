-- -----------------------------------------------------------------------------
-- Une séance de la montre arrivée avant sa séance                        (SAN-9)
--
-- `rattacher_activite` tourne à la réception. Une séance posée à la main après
-- coup, ou un coach activé après l'envoi, laisse l'activité sans séance alors
-- qu'une séance du même jour et de la même discipline existe. Chaque soir,
-- avant la clôture, ces activités des 28 derniers jours rejoignent la séance
-- la plus proche en heure. Aucune séance libre n'est créée ici.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rattacher_activites_orphelines(p_utilisateur INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    a            RECORD;
    v_occurrence INTEGER;
    v_nombre     INTEGER := 0;
BEGIN
    FOR a IN
        SELECT ac.id_activite, ac.discipline, lower(ac.periode) AS debut,
               jour_de(lower(ac.periode)) AS jour
          FROM activite_sante ac
         WHERE ac.id_utilisateur = p_utilisateur
           AND ac.id_occurrence IS NULL
           AND ac.discipline <> 'autre'
           AND jour_de(lower(ac.periode)) >= jour_de(now()) - 28
         ORDER BY lower(ac.periode)
    LOOP
        SELECT o.id_occurrence INTO v_occurrence
          FROM occurrence o JOIN seance se ON se.id_occurrence = o.id_occurrence
         WHERE o.id_utilisateur = p_utilisateur
           AND se.discipline = a.discipline
           AND jour_de(COALESCE(o.debut_seance, lower(o.fenetre))) = a.jour
           AND (o.statut IN ('a_placer', 'planifiee', 'notifiee', 'faite')
                OR (o.statut = 'abandonnee' AND o.motif = 'Pas faite'))
           AND NOT EXISTS (SELECT 1 FROM activite_sante x
                            WHERE x.id_occurrence = o.id_occurrence)
         ORDER BY abs(EXTRACT(EPOCH FROM (COALESCE(o.debut_seance, lower(o.fenetre))
                                          - a.debut)))
         LIMIT 1;
        CONTINUE WHEN v_occurrence IS NULL;

        UPDATE activite_sante SET id_occurrence = v_occurrence
         WHERE id_activite = a.id_activite;
        -- Une séance close comme pas faite l'était à tort : la montre l'a vue.
        UPDATE occurrence SET statut = 'faite', motif = NULL,
               date_faite = COALESCE(date_faite, a.debut)
         WHERE id_occurrence = v_occurrence
           AND statut = 'abandonnee' AND motif = 'Pas faite';
        PERFORM deduire_intensite(v_occurrence);
        v_nombre := v_nombre + 1;
    END LOOP;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION rattacher_activites_orphelines(INTEGER) IS
    'SAN-9 : rattache chaque soir, avant la clôture, les séances de la montre
     des 28 derniers jours restées sans séance alors qu''une séance du même
     jour et de la même discipline existe. Ne crée aucune séance libre.';
