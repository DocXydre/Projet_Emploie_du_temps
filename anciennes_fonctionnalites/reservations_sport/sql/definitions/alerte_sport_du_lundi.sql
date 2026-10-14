-- -----------------------------------------------------------------------------
-- L'alerte du lundi, personne par personne                     (SPT-27, SPT-28)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION alerte_sport_du_lundi() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    u          INTEGER;
    v_lundi    DATE := lundi_de(jour_de(now()));
    v_minimum  INTEGER;
    v_choisies INTEGER;
    v_reserve  TEXT;
    v_contenu  TEXT;
    v_n        INTEGER := 0;
BEGIN
    FOR u IN SELECT s FROM sportifs() s LOOP
        v_minimum := minimum_sport(u);
        -- Fréquence à zéro : pas de sport organisé, donc pas de relance.
        CONTINUE WHEN v_minimum <= 0;

        PERFORM organiser_sport_semaine(u, v_lundi);

        SELECT count(*) INTO v_choisies
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = u
           AND t.code = 'SPORT'
           AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee', 'faite')
           AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) BETWEEN v_lundi AND v_lundi + 6;

        CONTINUE WHEN v_choisies >= v_minimum;

        SELECT string_agg('• ' || to_char(o.debut_seance AT TIME ZONE 'Europe/Paris',
                                          'DD/MM à HH24hMI')
                          || COALESCE(' (proposé : ' || l.libelle || ')', ''),
                          E'\n' ORDER BY o.debut_seance)
          INTO v_reserve
          FROM occurrence o
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_utilisateur = u
           AND o.origine = 'quota'
           AND o.statut IN ('planifiee', 'notifiee')
           AND jour_de(o.debut_seance) BETWEEN v_lundi AND v_lundi + 6;

        v_contenu := CASE WHEN v_choisies = 0
                          THEN 'Sport : rien n''est choisi pour cette semaine.'
                          ELSE format('Sport : %s séance(s) choisie(s) sur %s minimum cette semaine.',
                                      v_choisies, v_minimum) END;
        IF v_reserve IS NOT NULL THEN
            v_contenu := v_contenu || E'\n\nÀ déterminer, réservé dans ton calendrier :\n'
                         || v_reserve;
        ELSE
            v_contenu := v_contenu || E'\n\nAucun créneau libre n''a pu être réservé.';
        END IF;

        INSERT INTO notification (id_utilisateur, type, contenu)
        VALUES (u, 'sport', v_contenu);
        v_n := v_n + 1;
    END LOOP;

    RETURN v_n;
END $$;

COMMENT ON FUNCTION alerte_sport_du_lundi IS
    'Un message le lundi matin par compte dont la semaine n''atteint pas son
     minimum. Une fréquence à zéro ne reçoit rien (SPT-27, SPT-28).';
