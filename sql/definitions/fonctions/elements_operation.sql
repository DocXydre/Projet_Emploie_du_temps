-- -----------------------------------------------------------------------------
-- Ce qu'une opération du coach a réellement écrit             (COA-18, COA-24)
--
-- Les éléments d'une réponse ne viennent jamais du modèle : ils se relisent
-- ici, dans l'ordre, à partir de la trace laissée par les fonctions. Un bouton
-- n'existe que si ce qu'il déclenche existe. Une séance proposée puis retirée
-- dans la même opération ne laisse rien.
--
-- C'est aussi ce qu'un nouvel essai reçoit, pour terminer au lieu de
-- recommencer.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION elements_operation(p_operation TEXT)
RETURNS JSONB LANGUAGE sql STABLE AS $$
    WITH derniere AS (
        -- Une ligne par objet : la dernière fois que l'opération y a touché.
        SELECT DISTINCT ON (t.type, t.id_objet)
               t.id_trace, t.type, t.id_objet, t.detail, t.id_utilisateur
          FROM trace_coach t
         WHERE t.operation = p_operation
         ORDER BY t.type, t.id_objet, t.id_trace DESC
    ),
    elements AS (
        SELECT d.id_trace, jsonb_build_object(
                   'type', 'seance_proposee',
                   'id_occurrence', o.id_occurrence,
                   'jour', jour_de(o.debut_seance),
                   'debut', o.debut_seance,
                   'lieu', l.libelle,
                   'discipline', se.discipline,
                   'type_seance', se.type_seance,
                   'duree_minutes', se.duree_minutes,
                   'intensite', se.intensite,
                   'cle', se.cle,
                   'esquisse', NOT EXISTS (SELECT 1 FROM seance_exercice x
                                            WHERE x.id_occurrence = se.id_occurrence)) AS element
          FROM derniere d
          JOIN occurrence o ON o.id_occurrence = d.id_objet
          JOIN seance se    ON se.id_occurrence = o.id_occurrence
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE d.type = 'seance_proposee' AND se.etat = 'proposee'
           AND o.statut IN ('planifiee', 'notifiee')
        UNION ALL
        SELECT d.id_trace, jsonb_build_object('type', 'seance_retiree') || d.detail
          FROM derniere d
         WHERE d.type = 'seance_retiree'
           -- Proposée puis retirée dans la même opération : rien à montrer.
           AND NOT EXISTS (SELECT 1 FROM trace_coach t
                            WHERE t.operation = p_operation
                              AND t.type = 'seance_proposee' AND t.id_objet = d.id_objet)
        UNION ALL
        SELECT d.id_trace, jsonb_build_object(
                   'type', 'ajustement',
                   'id_ajustement', a.id_ajustement,
                   'id_occurrence', a.id_occurrence,
                   'jour', jour_de(o.debut_seance),
                   'debut', o.debut_seance,
                   'discipline', se.discipline,
                   'type_seance', se.type_seance,
                   'nature', a.nature,
                   'motif', a.motif,
                   'en_place', jsonb_build_object(
                       'duree_minutes', se.duree_minutes, 'intensite', se.intensite,
                       'type_seance', se.type_seance),
                   'propose', a.contenu)
          FROM derniere d
          JOIN ajustement a ON a.id_ajustement = d.id_objet
          JOIN occurrence o ON o.id_occurrence = a.id_occurrence
          JOIN seance se    ON se.id_occurrence = a.id_occurrence
         WHERE d.type = 'ajustement' AND a.statut = 'propose'
        UNION ALL
        SELECT d.id_trace, jsonb_build_object(
                   'type', 'fenetre_mesure',
                   'id_fenetre', f.id_fenetre,
                   'type_mesure', f.type_mesure,
                   'du', lower(f.periode), 'au', upper(f.periode) - 1,
                   'consigne', f.consigne)
          FROM derniere d
          JOIN fenetre_mesure f ON f.id_fenetre = d.id_objet
         WHERE d.type = 'fenetre_mesure' AND f.statut = 'ouverte'
        UNION ALL
        SELECT d.id_trace, jsonb_build_object(
                   'type', 'avis_objectif',
                   'id_objectif', ob.id_objectif,
                   'libelle', ob.libelle,
                   'avis', ob.avis, 'detail', ob.avis_detail)
          FROM derniere d
          JOIN objectif ob ON ob.id_objectif = d.id_objet
         WHERE d.type = 'avis_objectif'
        UNION ALL
        SELECT d.id_trace, jsonb_build_object(
                   'type', 'avis_seance_libre',
                   'id_occurrence', se.id_occurrence,
                   'jour', jour_de(COALESCE(o.debut_seance, lower(o.fenetre))),
                   'discipline', se.discipline,
                   'avis', se.avis_libre, 'detail', se.avis_detail)
          FROM derniere d
          JOIN seance se    ON se.id_occurrence = d.id_objet
          JOIN occurrence o ON o.id_occurrence = se.id_occurrence
         WHERE d.type = 'avis_seance_libre'
        UNION ALL
        SELECT d.id_trace, jsonb_build_object(
                   'type', 'plan',
                   'id_plan', p.id_plan,
                   'du', lower(p.periode), 'au', upper(p.periode) - 1,
                   'semaines', (SELECT jsonb_agg(jsonb_build_object(
                                           'lundi', ps.lundi, 'role', ps.role)
                                       ORDER BY ps.lundi)
                                  FROM plan_semaine ps WHERE ps.id_plan = p.id_plan))
          FROM derniere d
          JOIN plan p ON p.id_plan = d.id_objet
         WHERE d.type = 'plan'
        UNION ALL
        -- Une semaine entièrement détaillée, avec des séances proposées par
        -- cette opération, attend d'être validée (PLN-6, PLN-24).
        SELECT w.id_trace + 0.5, jsonb_build_object(
                   'type', 'semaine_a_valider',
                   'lundi', w.lundi,
                   'seances', (SELECT count(*) FROM v_seance_coach x
                                WHERE x.id_utilisateur = w.id_utilisateur
                                  AND x.lundi = w.lundi
                                  AND x.auteur = 'coach'
                                  AND x.situation = 'proposee'))
          FROM (SELECT o.id_utilisateur,
                       lundi_de(jour_de(o.debut_seance)) AS lundi,
                       max(d.id_trace) AS id_trace
                  FROM derniere d
                  JOIN occurrence o ON o.id_occurrence = d.id_objet
                  JOIN seance se    ON se.id_occurrence = o.id_occurrence
                 WHERE d.type = 'seance_proposee' AND se.etat = 'proposee'
                   AND o.statut IN ('planifiee', 'notifiee')
                 GROUP BY 1, 2) w
         WHERE NOT EXISTS (SELECT 1 FROM v_seance_coach x
                            WHERE x.id_utilisateur = w.id_utilisateur
                              AND x.lundi = w.lundi
                              AND x.auteur = 'coach'
                              AND x.situation = 'esquisse')
    )
    SELECT COALESCE(jsonb_agg(e.element ORDER BY e.id_trace), '[]') FROM elements e;
$$;

COMMENT ON FUNCTION elements_operation(TEXT) IS
    'COA-18, COA-24 : la liste de ce qu''une opération du coach a écrit et qui
     existe encore : séances, ajustements, fenêtres, avis, plan, semaine à
     valider. Le module ne lit aucun élément dans la sortie du modèle.';
