CREATE OR REPLACE FUNCTION rappeler_semaine_a_valider() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    s        RECORD;
    v_creees INTEGER := 0;
BEGIN
    FOR s IN
        SELECT o.id_utilisateur, lundi_de(jour_de(o.debut_seance)) AS lundi, count(*) AS nombre
          FROM occurrence o
          JOIN seance se     ON se.id_occurrence = o.id_occurrence
          JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
         WHERE u.coach_actif AND u.actif
           AND se.auteur = 'coach' AND se.etat = 'proposee'
           AND o.statut IN ('planifiee', 'notifiee')
           AND lundi_de(jour_de(o.debut_seance)) <= lundi_de(jour_de(now()))
           AND NOT en_pause(o.id_utilisateur)
           AND NOT EXISTS (SELECT 1 FROM seance x JOIN occurrence ox
                               ON ox.id_occurrence = x.id_occurrence
                            WHERE ox.id_utilisateur = o.id_utilisateur
                              AND x.auteur = 'coach' AND x.etat = 'proposee'
                              AND ox.statut IN ('planifiee', 'notifiee')
                              AND lundi_de(jour_de(ox.debut_seance))
                                  = lundi_de(jour_de(o.debut_seance))
                              AND NOT EXISTS (SELECT 1 FROM seance_exercice e
                                               WHERE e.id_occurrence = x.id_occurrence))
         GROUP BY 1, 2
    LOOP
        INSERT INTO notification (id_utilisateur, type, contenu)
        VALUES (s.id_utilisateur, 'coach',
                format('Ta semaine de sport du %s attend d''être validée : %s séance(s) '
                       || 'proposée(s). /semaine pour les voir.',
                       to_char(s.lundi, 'DD/MM'), s.nombre));
        v_creees := v_creees + 1;
    END LOOP;
    RETURN v_creees;
END $$;

COMMENT ON FUNCTION rappeler_semaine_a_valider() IS
    'NOT-12 : le matin, dit quand la semaine en cours attend d''être validée.';
