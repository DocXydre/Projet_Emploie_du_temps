-- =============================================================================
-- 066 : la fenêtre d'un test suit sa séance                          (MES-6)
--
-- Rejouable.
--
-- Une fenêtre de test ouverte sans séance rattachée s'annonçait à ses propres
-- dates, un samedi par exemple, alors que la séance de test du plan était le
-- vendredi. Chaque fenêtre de test ouverte se rattache à la séance de test la
-- plus proche et prend son jour. Celle qui n'en trouve aucune est close comme
-- expirée : HAL reproposera le test comme une séance.
-- =============================================================================

WITH rattachement AS (
    SELECT DISTINCT ON (f.id_fenetre) f.id_fenetre, o.id_occurrence,
           jour_de(COALESCE(o.debut_seance, lower(o.creneau), lower(o.fenetre))) AS jour
      FROM fenetre_mesure f
      JOIN occurrence o ON o.id_utilisateur = f.id_utilisateur
      JOIN seance se    ON se.id_occurrence = o.id_occurrence AND se.est_test
     WHERE f.statut = 'ouverte'
       AND f.id_occurrence IS NULL
       AND f.type_mesure IN ('test_course', 'test_force')
       AND o.statut IN ('planifiee', 'notifiee')
       AND (se.discipline IS NULL
            OR (f.type_mesure = 'test_course' AND se.discipline IN ('course', 'cardio'))
            OR (f.type_mesure = 'test_force' AND se.discipline = 'musculation'))
       AND jour_de(COALESCE(o.debut_seance, lower(o.creneau), lower(o.fenetre)))
           BETWEEN lower(f.periode) - 7 AND upper(f.periode) + 7
     ORDER BY f.id_fenetre,
              abs(jour_de(COALESCE(o.debut_seance, lower(o.creneau), lower(o.fenetre)))
                  - lower(f.periode))
)
UPDATE fenetre_mesure f
   SET id_occurrence = r.id_occurrence,
       periode       = daterange(r.jour, r.jour + 1, '[]')
  FROM rattachement r
 WHERE r.id_fenetre = f.id_fenetre;

UPDATE fenetre_mesure
   SET statut = 'expiree'
 WHERE statut = 'ouverte'
   AND id_occurrence IS NULL
   AND type_mesure IN ('test_course', 'test_force');
