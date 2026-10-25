-- -----------------------------------------------------------------------------
-- Ce qui va ensemble se fait le même jour                      (TAC-15, TAC-16)
--
-- Le placement pose chaque tâche seule. Cette passe vient après lui et
-- rapproche celles qui vont ensemble : quand la tâche qui mène est prévue un
-- jour, celle qui l'accompagne vient ce jour-là, pour la même personne.
--
--   TAC-15  Récurer emmène l'aspirateur, avant. La poussière l'emmène, après.
--   TAC-16  Le titre de chaque occurrence dit sa place.
--
-- Le bloc « Nettoyage » des jours sans cours n'est plus une règle : il est dans
-- la description de la poussière et du récurage, que HAL applique (TAC-29).
--
-- C'est l'occurrence la plus proche de la tâche jointe qui se déplace, et non
-- une occurrence de plus : passer l'aspirateur mardi avec le récurage tient
-- lieu de celui qui était prévu mercredi. On n'en crée une que si aucune n'est
-- à portée.
--
-- Une tâche déjà annoncée ou épinglée ne se déplace pas. Elle peut en revanche
-- mener : son jour est connu, et l'autre la rejoint.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION poser_les_accompagnements() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    a           RECORD;
    o           RECORD;
    v_jointe    INTEGER;
    v_ecart     INTEGER;
    -- Ce qui a déjà trouvé sa place pendant cette passe ne bouge plus.
    v_fixees    INTEGER[] := '{}';
    v_deplacees INTEGER := 0;
BEGIN
    -- Les titres se refont à chaque passe : un cours ajouté déplace une tâche.
    UPDATE occurrence SET titre = NULL
     WHERE titre IS NOT NULL
       AND statut IN ('a_placer', 'planifiee', 'notifiee');

    FOR a IN
        SELECT ac.*, tj.periodicite_min_jours, tj.periodicite_max_jours
          FROM accompagnement ac
          JOIN tache tm ON tm.id_tache = ac.id_tache
          JOIN tache tj ON tj.id_tache = ac.id_tache_jointe
         WHERE tm.active AND tj.active
           -- Un rappel de journée n'a pas d'heure : « le même jour » suffit à
           -- le poser. Une tâche à heure imposée demanderait un vrai créneau.
           AND tm.rappel_journee AND tj.rappel_journee
         ORDER BY ac.id_accompagnement
    LOOP
        -- La plus proche, sans aller plus loin que sa période : une tâche
        -- sans rythme se rapproche à une semaine près.
        v_ecart := COALESCE(a.periodicite_max_jours, 7);

        FOR o IN
            SELECT id_occurrence, id_utilisateur, jour_de(lower(creneau)) AS jour
              FROM occurrence
             WHERE id_tache = a.id_tache
               AND statut IN ('planifiee', 'notifiee')
               AND creneau IS NOT NULL
               AND id_utilisateur IS NOT NULL
               AND jour_de(lower(creneau)) >= jour_de(now())
             ORDER BY lower(creneau), id_occurrence
        LOOP
            -- Déjà là, ou déjà faite ce jour-là : rien à rapprocher.
            SELECT j.id_occurrence INTO v_jointe
              FROM occurrence j
             WHERE j.id_tache = a.id_tache_jointe
               AND j.id_utilisateur = o.id_utilisateur
               AND j.statut IN ('planifiee', 'notifiee')
               AND j.creneau IS NOT NULL
               AND jour_de(lower(j.creneau)) = o.jour
             LIMIT 1;

            IF v_jointe IS NULL THEN
                CONTINUE WHEN EXISTS (
                    SELECT 1 FROM occurrence j
                     WHERE j.id_tache = a.id_tache_jointe
                       AND j.statut = 'faite'
                       AND jour_de(j.date_faite) = o.jour);

                SELECT j.id_occurrence INTO v_jointe
                  FROM occurrence j
                 WHERE j.id_tache = a.id_tache_jointe
                   AND j.statut IN ('a_placer', 'planifiee')
                   AND NOT j.epinglee
                   AND j.id_occurrence <> ALL (v_fixees)
                   AND abs(jour_de(lower(COALESCE(j.creneau, j.fenetre))) - o.jour) <= v_ecart
                 ORDER BY abs(jour_de(lower(COALESCE(j.creneau, j.fenetre))) - o.jour),
                          lower(j.fenetre) DESC
                 LIMIT 1;

                IF v_jointe IS NOT NULL THEN
                    UPDATE occurrence
                       SET fenetre        = tstzrange(debut_jour(o.jour), debut_jour(o.jour + 1), '[)'),
                           creneau        = tstzrange(debut_jour(o.jour), debut_jour(o.jour + 1), '[)'),
                           id_utilisateur = o.id_utilisateur,
                           statut         = 'planifiee',
                           motif          = format('À faire le %s', to_char(o.jour, 'DD/MM'))
                     WHERE id_occurrence = v_jointe;
                ELSE
                    -- Aucune à déplacer : les plus proches accompagnent déjà
                    -- autre chose. L'aspirateur après la poussière n'est pas
                    -- négociable, on en pose un. C'est une prévision comme les
                    -- autres : elle disparaîtra à la prochaine validation.
                    INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau,
                                            statut, origine, motif)
                    VALUES (a.id_tache_jointe, o.id_utilisateur,
                            tstzrange(debut_jour(o.jour), debut_jour(o.jour + 1), '[)'),
                            tstzrange(debut_jour(o.jour), debut_jour(o.jour + 1), '[)'),
                            'planifiee', 'recurrence',
                            format('À faire le %s', to_char(o.jour, 'DD/MM')))
                    RETURNING id_occurrence INTO v_jointe;
                END IF;

                v_deplacees := v_deplacees + 1;
            END IF;

            v_fixees := v_fixees || v_jointe || o.id_occurrence;
        END LOOP;
    END LOOP;

    -- ---- TAC-16 : les titres -----------------------------------------------
    --
    -- À deux : celle qui accompagne dit ce qu'elle accompagne. Poussière et
    -- récurage le même jour partagent un aspirateur, qui dit les deux, dans
    -- l'ordre de la journée : « (après la poussière, avant de récurer) ».
    UPDATE occurrence j
       SET titre = x.libelle || ' (' || x.mentions || ')'
      FROM (SELECT d.id_occurrence, d.libelle,
                   string_agg(d.mention, ', ' ORDER BY d.place = 'avant',
                              d.id_accompagnement) AS mentions
              FROM (SELECT DISTINCT j.id_occurrence, tj.libelle, ac.id_accompagnement,
                                    ac.place, ac.mention
                      FROM accompagnement ac
                      JOIN tache tj ON tj.id_tache = ac.id_tache_jointe
                      JOIN occurrence j ON j.id_tache = ac.id_tache_jointe
                      JOIN occurrence m ON m.id_tache = ac.id_tache
                     WHERE ac.mention IS NOT NULL
                       AND m.statut IN ('planifiee', 'notifiee')
                       AND j.statut IN ('planifiee', 'notifiee')
                       AND m.creneau IS NOT NULL
                       AND j.creneau IS NOT NULL
                       AND m.id_utilisateur = j.id_utilisateur
                       AND jour_de(lower(m.creneau)) = jour_de(lower(j.creneau))
                       AND jour_de(lower(m.creneau)) >= jour_de(now())) d
             GROUP BY d.id_occurrence, d.libelle) x
     WHERE j.id_occurrence = x.id_occurrence;

    RETURN v_deplacees;
END $$;

COMMENT ON FUNCTION poser_les_accompagnements() IS
    'TAC-15, TAC-16 : rapproche les tâches qui vont ensemble et leur donne un
     titre qui dit leur place. Appelée à la fin de chaque placement.';
