-- Les séances de sport, avec leur contenu résumé et ce qui a été fait.
-- Une occurrence de sport sans ligne dans `seance` y figure aussi : c'est la
-- séance posée à la main, sans contenu (SPT-17).
CREATE VIEW v_seance_coach AS
SELECT o.id_occurrence,
       o.id_utilisateur,
       jour_de(COALESCE(o.debut_seance, lower(o.creneau), lower(o.fenetre)))           AS jour,
       lundi_de(jour_de(COALESCE(o.debut_seance, lower(o.creneau), lower(o.fenetre)))) AS lundi,
       COALESCE(o.debut_seance, lower(o.creneau))                                      AS debut,
       o.id_lieu,
       l.libelle                                    AS lieu,
       o.statut                                     AS statut_occurrence,
       o.motif,
       COALESCE(se.auteur, 'utilisateur')           AS auteur,
       se.etat,
       COALESCE(se.libre, FALSE)                    AS libre,
       COALESCE(se.annoncee, FALSE)                 AS annoncee,
       se.discipline,
       se.type_seance,
       se.intensite,
       COALESCE(se.cle, FALSE)                      AS cle,
       COALESCE(se.est_test, FALSE)                 AS est_test,
       se.duree_minutes,
       se.groupes,
       se.consigne,
       se.id_plan,
       se.id_occurrence_remplacee,
       se.avis_libre,
       (se.auteur = 'coach' AND x.exercices = 0)    AS esquisse,
       x.exercices,
       x.series_saisies,
       b.effort,
       b.duree_minutes                              AS duree_reelle,
       -- SAI-13 : sans bilan, pas de charge. Une donnée absente, pas un zéro.
       b.effort * b.duree_minutes                   AS charge,
       b.commentaire,
       x.activite                                   AS activite_montre,
       CASE
           WHEN o.statut = 'faite' OR b.id_occurrence IS NOT NULL OR x.activite THEN 'faite'
           WHEN o.statut = 'abandonnee' AND o.motif LIKE 'Remplacée%' THEN 'remplacee'
           WHEN o.statut = 'abandonnee' AND o.motif LIKE 'Retirée%'   THEN 'retiree'
           WHEN o.statut IN ('abandonnee', 'reportee')               THEN 'pas_faite'
           WHEN se.id_occurrence IS NULL                              THEN 'posee_a_la_main'
           WHEN se.auteur = 'coach' AND x.exercices = 0              THEN 'esquisse'
           ELSE se.etat
       END                                          AS situation
  FROM occurrence o
  JOIN tache t           ON t.id_tache = o.id_tache AND t.categorie = 'sport'
  LEFT JOIN seance se    ON se.id_occurrence = o.id_occurrence
  LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
  LEFT JOIN bilan_seance b ON b.id_occurrence = o.id_occurrence
  CROSS JOIN LATERAL (
      SELECT (SELECT count(*) FROM seance_exercice e
               WHERE e.id_occurrence = o.id_occurrence)::INTEGER AS exercices,
             (SELECT count(*) FROM serie_saisie s
               WHERE s.id_occurrence = o.id_occurrence)::INTEGER AS series_saisies,
             EXISTS (SELECT 1 FROM activite_sante a
                      WHERE a.id_occurrence = o.id_occurrence)   AS activite
  ) x
 WHERE o.origine <> 'quota';

COMMENT ON VIEW v_seance_coach IS
    'PLN-4, PLN-6, SAI-13 : chaque séance de sport, son état, son contenu
     résumé et ce qui a été fait. La colonne situation dit en un mot où elle en
     est : esquisse, proposee, validee, faite, pas_faite, remplacee.';
