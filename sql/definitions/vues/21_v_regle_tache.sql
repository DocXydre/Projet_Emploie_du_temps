-- -----------------------------------------------------------------------------
-- Les règles des tâches, avec leurs briques                     (CND-2, CND-16)
--
-- Ce que l'appli montre dans le détail d'une tâche : la traduction, la période,
-- la fréquence, l'état, les briques pour « Modifier à la main », et ce qu'il
-- reste à faire de son rappel « impossible ». Le prochain jour possible se
-- demande à part (`jours_possibles`) : le calculer pour chaque ligne coûterait
-- huit semaines de jours à chaque lecture.
-- -----------------------------------------------------------------------------
CREATE VIEW v_regle_tache AS
SELECT r.id_regle_tache, r.id_tache, t.libelle AS tache, r.phrase, r.traduction,
       lower(r.validite) AS valide_du, (upper(r.validite) - 1) AS valide_au,
       r.chaque_annee,
       CASE WHEN r.rythme_nombre IS NOT NULL
                THEN jsonb_build_object('fois', r.rythme_nombre, 'par', r.rythme_periode)
            WHEN r.periodicite_min_jours IS NOT NULL
                THEN jsonb_build_object('min', r.periodicite_min_jours, 'max', r.periodicite_max_jours)
       END AS frequence,
       r.etat, r.posee_par, u.nom AS posee_par_nom, r.id_demande, r.creee_le,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                            'nature', b.nature, 'pour_qui', b.pour_qui,
                            'id_utilisateur', b.id_utilisateur, 'parametres', b.parametres,
                            'phrase', phrase_brique(b.nature, b.pour_qui, b.id_utilisateur,
                                                    b.parametres))
                        ORDER BY b.id_brique_regle)
                   FROM brique_regle b WHERE b.id_regle_tache = r.id_regle_tache),
                '[]'::JSONB) AS briques,
       (SELECT max(h.declenche_le) FROM rappel_hal h
         WHERE h.id_regle_tache = r.id_regle_tache AND h.etat = 'attente'
           AND h.evenement = 'impossible'
           -- Le placement la signale chaque jour tant qu'elle l'est : au-delà
           -- d'un jour sans signal, elle ne l'est plus.
           AND h.declenche_le > now() - INTERVAL '26 hours') AS impossible_depuis
  FROM regle_tache r
  JOIN tache t ON t.id_tache = r.id_tache
  JOIN utilisateur u ON u.id_utilisateur = r.posee_par;
