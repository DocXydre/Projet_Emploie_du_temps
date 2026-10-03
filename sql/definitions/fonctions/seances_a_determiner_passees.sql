-- -----------------------------------------------------------------------------
-- Les réservations passées sans être choisies                          (SPT-25)
--
-- Pas de « c'est fait ? » : on ne l'avait pas choisie, on ne l'a donc pas
-- faite. Un message le dit, et rappelle ce qui reste réservé cette semaine,
-- la réservation manquée ayant été reproposée plus loin quand la semaine le
-- permet.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seances_a_determiner_passees() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    g         RECORD;
    v_reste   TEXT;
    v_contenu TEXT;
    v_n       INTEGER := 0;
BEGIN
    -- Groupées par personne et par semaine : si le serveur a dormi, trois
    -- réservations manquées font un message, pas trois.
    FOR g IN
        SELECT o.id_utilisateur, lundi_de(jour_de(o.debut_seance)) AS lundi,
               string_agg(to_char(o.debut_seance AT TIME ZONE 'Europe/Paris', 'DD/MM'),
                          ', ' ORDER BY o.debut_seance) AS jours,
               count(*) AS nombre
          FROM occurrence o
         WHERE o.origine = 'quota'
           AND o.statut IN ('planifiee', 'notifiee')
           AND upper(o.creneau) <= now()
         GROUP BY o.id_utilisateur, lundi_de(jour_de(o.debut_seance))
    LOOP
        UPDATE occurrence o
           SET statut = 'abandonnee',
               motif  = 'À déterminer, passée sans être choisie'
         WHERE o.origine = 'quota'
           AND o.id_utilisateur = g.id_utilisateur
           AND o.statut IN ('planifiee', 'notifiee')
           AND upper(o.creneau) <= now()
           AND lundi_de(jour_de(o.debut_seance)) = g.lundi;

        PERFORM organiser_sport_semaine(g.id_utilisateur, g.lundi);

        SELECT string_agg('• ' || to_char(o.debut_seance AT TIME ZONE 'Europe/Paris',
                                          'DD/MM à HH24hMI')
                          || COALESCE(' (proposé : ' || l.libelle || ')', ''),
                          E'\n' ORDER BY o.debut_seance)
          INTO v_reste
          FROM occurrence o
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_utilisateur = g.id_utilisateur
           AND o.origine = 'quota'
           AND o.statut IN ('planifiee', 'notifiee')
           AND lower(o.creneau) > now()
           AND jour_de(o.debut_seance) BETWEEN g.lundi AND g.lundi + 6;

        v_contenu := format('Pas de sport le %s : la séance à déterminer est passée '
                            'sans être choisie.', g.jours);
        IF g.lundi + 7 <= jour_de(now()) THEN
            NULL;   -- la semaine est finie, il n'y a rien à reproposer
        ELSIF v_reste IS NOT NULL THEN
            v_contenu := v_contenu || E'\n\nCe qui reste réservé cette semaine :\n' || v_reste;
        ELSE
            v_contenu := v_contenu || E'\n\nPlus aucun créneau libre d''ici dimanche.';
        END IF;

        INSERT INTO notification (id_utilisateur, type, contenu)
        VALUES (g.id_utilisateur, 'sport', v_contenu);
        v_n := v_n + g.nombre;
    END LOOP;

    RETURN v_n;
END $$;
