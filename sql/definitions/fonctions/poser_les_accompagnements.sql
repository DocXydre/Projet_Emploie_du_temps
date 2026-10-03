-- -----------------------------------------------------------------------------
-- Ce qui va ensemble se fait le même jour                      (TAC-15 à TAC-17)
--
-- Le placement pose chaque tâche seule. Cette passe vient après lui et
-- rapproche celles qui vont ensemble : quand la tâche qui mène est prévue un
-- jour, celle qui l'accompagne vient ce jour-là, pour la même personne.
--
--   TAC-15  Récurer emmène l'aspirateur, avant. La poussière l'emmène, après.
--   TAC-17  Un jour sans cours ni travail, poussière et récurage se rejoignent
--           et forment un bloc : poussière, aspirateur, récurage.
--   TAC-16  Le titre de chaque occurrence dit sa place.
--
-- C'est l'occurrence la plus proche de la tâche jointe qui se déplace, et non
-- une occurrence de plus : passer l'aspirateur mardi avec le récurage tient
-- lieu de celui qui était prévu mercredi. On n'en crée une que si aucune n'est
-- à portée. Pour un bloc, on n'avance pas une
-- tâche de plus du tiers de sa période : refaire la poussière trois jours
-- après l'avoir faite n'est pas un coup de ménage en plus, c'est du zèle.
--
-- Une tâche déjà annoncée ou épinglée ne se déplace pas. Elle peut en revanche
-- mener : son jour est connu, et l'autre la rejoint.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION poser_les_accompagnements() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    a           RECORD;
    o           RECORD;
    b           RECORD;
    v_jointe    INTEGER;
    v_ecart     INTEGER;
    -- Ce qui a déjà trouvé sa place pendant cette passe ne bouge plus.
    v_fixees    INTEGER[] := '{}';
    v_deplacees INTEGER := 0;
BEGIN
    -- Les titres se refont à chaque passe : un cours ajouté défait un bloc.
    UPDATE occurrence SET titre = NULL
     WHERE titre IS NOT NULL
       AND statut IN ('a_placer', 'planifiee', 'notifiee');

    -- Les blocs d'abord : ils rapprochent deux tâches qui mènent, et
    -- l'aspirateur suit ensuite celle qui a bougé.
    FOR a IN
        SELECT ac.*, tj.periodicite_min_jours, tj.periodicite_max_jours
          FROM accompagnement ac
          JOIN tache tm ON tm.id_tache = ac.id_tache
          JOIN tache tj ON tj.id_tache = ac.id_tache_jointe
         WHERE tm.active AND tj.active
           -- Un rappel de journée n'a pas d'heure : « le même jour » suffit à
           -- le poser. Une tâche à heure imposée demanderait un vrai créneau.
           AND tm.rappel_journee AND tj.rappel_journee
         ORDER BY ac.journee_libre DESC, ac.id_accompagnement
    LOOP
        v_ecart := CASE WHEN a.journee_libre THEN a.periodicite_min_jours / 3
                        ELSE a.periodicite_max_jours END;

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
            CONTINUE WHEN a.journee_libre
                      AND NOT journee_libre(o.id_utilisateur, o.jour);

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
                ELSIF NOT a.journee_libre THEN
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
                ELSE
                    -- Un bloc est un bonus : sans tâche à avancer, pas de bloc.
                    CONTINUE;
                END IF;

                v_deplacees := v_deplacees + 1;
            END IF;

            v_fixees := v_fixees || v_jointe || o.id_occurrence;
        END LOOP;
    END LOOP;

    -- ---- TAC-16 : les titres -----------------------------------------------
    --
    -- À deux : celle qui accompagne dit ce qu'elle accompagne.
    UPDATE occurrence j
       SET titre = tj.libelle || ' (' || ac.mention || ')'
      FROM accompagnement ac
      JOIN tache tj ON tj.id_tache = ac.id_tache_jointe,
           occurrence m
     WHERE NOT ac.journee_libre
       AND ac.mention IS NOT NULL
       AND m.id_tache = ac.id_tache
       AND j.id_tache = ac.id_tache_jointe
       AND m.statut IN ('planifiee', 'notifiee')
       AND j.statut IN ('planifiee', 'notifiee')
       AND m.creneau IS NOT NULL
       AND j.creneau IS NOT NULL
       AND m.id_utilisateur = j.id_utilisateur
       AND jour_de(lower(m.creneau)) = jour_de(lower(j.creneau))
       AND jour_de(lower(m.creneau)) >= jour_de(now());

    -- En bloc : « Nettoyage 1/3 : Faire la poussière ». Le rang d'une tâche est
    -- le nombre de celles qui doivent passer avant elle.
    FOR b IN
        SELECT DISTINCT ac.bloc, m.id_utilisateur, jour_de(lower(m.creneau)) AS jour
          FROM accompagnement ac
          JOIN occurrence m ON m.id_tache = ac.id_tache
          JOIN occurrence j ON j.id_tache = ac.id_tache_jointe
         WHERE ac.journee_libre
           AND m.statut IN ('planifiee', 'notifiee') AND m.creneau IS NOT NULL
           AND j.statut IN ('planifiee', 'notifiee') AND j.creneau IS NOT NULL
           AND m.id_utilisateur = j.id_utilisateur
           AND jour_de(lower(m.creneau)) = jour_de(lower(j.creneau))
           AND jour_de(lower(m.creneau)) >= jour_de(now())
           AND journee_libre(m.id_utilisateur, jour_de(lower(m.creneau)))
    LOOP
        WITH du_bloc AS (
            SELECT id_tache FROM accompagnement WHERE bloc = b.bloc
            UNION
            SELECT id_tache_jointe FROM accompagnement WHERE bloc = b.bloc
        ), taches AS (
            SELECT id_tache FROM du_bloc
            UNION
            -- Et ce que ces tâches emmènent de toute façon : l'aspirateur.
            SELECT p.id_tache_jointe FROM accompagnement p
             WHERE NOT p.journee_libre AND p.id_tache IN (SELECT id_tache FROM du_bloc)
        ), membres AS (
            SELECT oc.id_occurrence, oc.id_tache, t.libelle
              FROM occurrence oc
              JOIN tache t ON t.id_tache = oc.id_tache
             WHERE oc.id_tache IN (SELECT id_tache FROM taches)
               AND oc.id_utilisateur = b.id_utilisateur
               AND oc.statut IN ('planifiee', 'notifiee')
               AND oc.creneau IS NOT NULL
               AND jour_de(lower(oc.creneau)) = b.jour
        ), ranges AS (
            SELECT m.id_occurrence, m.libelle,
                   (SELECT count(DISTINCT x.id_tache)
                      FROM membres x
                     WHERE EXISTS (
                           SELECT 1 FROM accompagnement r
                            WHERE (r.id_tache = m.id_tache AND r.id_tache_jointe = x.id_tache
                                   AND r.place = 'avant')
                               OR (r.id_tache = x.id_tache AND r.id_tache_jointe = m.id_tache
                                   AND r.place = 'apres'))) AS avant
              FROM membres m
        )
        UPDATE occurrence oc
           SET titre = format('%s %s/%s : %s', b.bloc, r.avant + 1,
                              (SELECT count(*) FROM membres), r.libelle)
          FROM ranges r
         WHERE oc.id_occurrence = r.id_occurrence;
    END LOOP;

    RETURN v_deplacees;
END $$;

COMMENT ON FUNCTION poser_les_accompagnements() IS
    'TAC-15 à TAC-17 : rapproche les tâches qui vont ensemble et leur donne un
     titre qui dit leur place. Appelée à la fin de chaque placement.';
