-- -----------------------------------------------------------------------------
-- Occurrences, enrichies de tout ce que le client ne doit pas recalculer
-- -----------------------------------------------------------------------------
CREATE VIEW v_occurrence AS
SELECT
    o.id_occurrence,
    o.id_tache,
    t.code            AS tache_code,
    t.libelle         AS tache_libelle,
    t.categorie,
    t.priorite,
    t.duree_minutes,
    o.id_utilisateur,
    u.pseudo          AS assigne_a,
    o.fenetre,
    lower(o.fenetre)  AS echeance_min,
    upper(o.fenetre)  AS echeance_max,
    o.creneau,
    lower(o.creneau)  AS debut,
    upper(o.creneau)  AS fin,
    o.statut,
    o.origine,
    o.epinglee,
    o.rappel_journee,
    o.utilise_machine,
    o.nb_relances,
    o.motif,
    o.date_faite,

    -- EXE-4, EXE-6 : c'est la base qui dit qu'une tâche est en retard.
    --
    -- Deux façons de l'être : une échéance dépassée, ou au moins un report
    -- d'office. Le report repousse la fenêtre au lendemain, donc sans le
    -- compteur de relances une tâche repoussée chaque soir paraîtrait
    -- éternellement à l'heure.
    (o.statut IN ('a_placer', 'planifiee', 'notifiee')
     AND (upper(o.fenetre) < now() OR o.nb_relances > 0)) AS en_retard,

    CASE
        WHEN o.statut IN ('a_placer', 'planifiee', 'notifiee')
        THEN GREATEST(
                 o.nb_relances,
                 CASE WHEN upper(o.fenetre) < now()
                      THEN EXTRACT(DAY FROM now() - upper(o.fenetre))::INTEGER
                      ELSE 0 END)
        ELSE 0
    END                                                   AS jours_de_retard,

    -- EXE-5 : les transitions encore possibles, pour que le client sache quels
    -- boutons afficher sans connaître la machine à états.
    CASE o.statut
        WHEN 'a_placer'  THEN ARRAY['faite', 'reportee', 'abandonnee']
        WHEN 'planifiee' THEN ARRAY['notifiee', 'faite', 'reportee', 'abandonnee']
        WHEN 'notifiee'  THEN ARRAY['faite', 'reportee', 'abandonnee']
        ELSE ARRAY[]::VARCHAR[]
    END                                                   AS actions_possibles
FROM occurrence o
JOIN tache t          ON t.id_tache = o.id_tache
LEFT JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur;
