-- -----------------------------------------------------------------------------
-- Les règles de sécurité tenues par la base                      (SEC-1 à SEC-4)
--
-- Deux contrôles, vérifiables sans jugement.
--
--   SEC-1 : un exercice interdit par une limitation active du compte. Toujours
--   bloquant, quel que soit le mode.
--
--   SEC-3 : deux séances dures qui sollicitent un même groupe à moins du délai
--   du compte, de début à début. Bloquant en mode strict (le coach), simple
--   avertissement en mode souple (l'utilisateur).
--
-- Rend une ligne par problème, aucune si tout va bien.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obstacle_sportif(
    p_utilisateur INTEGER,
    p_debut       TIMESTAMPTZ,
    p_intensite   VARCHAR,
    p_groupes     TEXT[],
    p_exercices   INTEGER[] DEFAULT NULL,
    p_ignorer     INTEGER   DEFAULT NULL,
    p_strict      BOOLEAN   DEFAULT TRUE
) RETURNS TABLE (code TEXT, motif TEXT, bloquant BOOLEAN)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_repos INTEGER;
BEGIN
    RETURN QUERY
    SELECT 'exercice_interdit'::TEXT,
           format('%s est interdit par une limitation : %s', e.libelle, ei.motif),
           TRUE
      FROM exercice_interdit ei
      JOIN limitation l ON l.id_limitation = ei.id_limitation
      JOIN exercice e   ON e.id_exercice = ei.id_exercice
     WHERE l.id_utilisateur = p_utilisateur
       AND l.active
       AND ei.id_exercice = ANY (COALESCE(p_exercices, ARRAY[]::INTEGER[]));

    IF p_intensite IS DISTINCT FROM 'dure' OR p_debut IS NULL
       OR COALESCE(cardinality(p_groupes), 0) = 0 THEN
        RETURN;
    END IF;

    SELECT u.repos_dur_heures INTO v_repos
      FROM utilisateur u WHERE u.id_utilisateur = p_utilisateur;

    RETURN QUERY
    SELECT 'seances_dures_collees'::TEXT,
           format('séance dure (%s) à moins de %s h de celle du %s',
                  (SELECT string_agg(g, ', ')
                     FROM unnest(s.groupes) g WHERE g = ANY (p_groupes)),
                  v_repos,
                  to_char(x.debut AT TIME ZONE 'Europe/Paris', 'DD/MM à HH24hMI')),
           p_strict
      FROM seance s
      JOIN occurrence o ON o.id_occurrence = s.id_occurrence
      CROSS JOIN LATERAL (SELECT COALESCE(o.debut_seance, lower(o.creneau),
                                          o.date_faite) AS debut) x
     WHERE o.id_utilisateur = p_utilisateur
       AND s.intensite = 'dure'
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee', 'faite')
       AND o.id_occurrence IS DISTINCT FROM p_ignorer
       AND s.groupes && p_groupes
       AND x.debut IS NOT NULL
       AND abs(EXTRACT(EPOCH FROM (x.debut - p_debut))) < v_repos * 3600
     ORDER BY x.debut;
END $$;

COMMENT ON FUNCTION obstacle_sportif IS
    'SEC-1 à SEC-4 : exercice interdit par une limitation (toujours bloquant),
     séances dures collées (bloquant en mode strict, avertissement en mode
     souple). Une ligne par problème.';
