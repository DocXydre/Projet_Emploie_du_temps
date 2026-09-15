-- rejouable : ce fichier ne contient que des CREATE OR REPLACE.
-- =============================================================================
-- 026 : poser soi-même l'heure d'une séance                          (SPT-17)
--
-- `retenir_seance_sport` ne sait fixer qu'un créneau que le moteur a lui-même
-- calculé : on choisit un jour et un lieu, l'heure est imposée. Quand rien ne
-- convient, ou quand on sait qu'on ira à 18h parce qu'on y va avec quelqu'un,
-- il n'y avait aucun moyen de le dire.
--
-- L'heure donnée est celle de la séance, pas celle du bloc. On dit « je vais à
-- la salle à 18h », pas « je pars de chez moi à 17h20 ». Le trajet et les
-- marges s'ajoutent autour, et la fonction rend le bloc complet pour qu'on voie
-- ce qui est réellement réservé.
--
-- Poser une séance à la main reste soumis aux obligations : on ne se met pas en
-- cours ou en service. Le reste, c'est son affaire.
-- =============================================================================

CREATE OR REPLACE FUNCTION caler_seance_sport(
    p_utilisateur INTEGER,
    p_debut       TIMESTAMPTZ,
    p_lieu        INTEGER DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache      INTEGER;
    v_lieu       INTEGER;
    v_jour       DATE;
    v_duree      INTERVAL;
    v_trajet     INTERVAL;
    v_marge      INTERVAL;
    v_creneau    TSTZRANGE;
    v_occurrence INTEGER;
    v_obstacle   TEXT;
BEGIN
    SELECT t.id_tache INTO v_tache FROM tache t WHERE t.code = 'SPORT' AND t.active;
    IF v_tache IS NULL THEN
        RAISE EXCEPTION 'La tâche de sport est désactivée'
              USING ERRCODE = 'no_data_found';
    END IF;

    v_jour := jour_de(p_debut);

    IF est_absent(p_utilisateur, v_jour) THEN
        RAISE EXCEPTION 'Tu es absent ce jour-là'
              USING ERRCODE = 'check_violation';
    END IF;

    -- Faute de lieu donné, celui qu'on préfère d'ordinaire.
    v_lieu := COALESCE(p_lieu, (SELECT tl.id_lieu FROM tache_lieu tl
                                 WHERE tl.id_tache = v_tache
                                 ORDER BY tl.rang LIMIT 1));
    IF v_lieu IS NULL THEN
        RAISE EXCEPTION 'Aucun lieu de sport connu'
              USING ERRCODE = 'no_data_found';
    END IF;

    SELECT make_interval(mins => COALESCE(l.duree_minutes, t.duree_minutes)),
           make_interval(mins => l.marge_minutes)
      INTO v_duree, v_marge
      FROM lieu_sport l, tache t
     WHERE l.id_lieu = v_lieu AND t.id_tache = v_tache;

    v_trajet := make_interval(mins => trajet_minutes(p_utilisateur, v_jour, v_lieu));

    -- Le bloc réellement réservé : marge, trajet, séance, trajet, marge.
    v_creneau := tstzrange(p_debut - v_trajet - v_marge,
                           p_debut + v_duree + v_trajet + v_marge, '[)');

    -- On ne se met pas en cours ni en service. Le nom de l'obstacle vaut mieux
    -- qu'un refus sec : on saura quoi décaler.
    SELECT o.libelle INTO v_obstacle
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.type IN ('cours', 'travail')
       AND o.periode && v_creneau
     ORDER BY lower(o.periode)
     LIMIT 1;

    IF v_obstacle IS NOT NULL THEN
        RAISE EXCEPTION 'Ce créneau tombe sur « % »', v_obstacle
              USING ERRCODE = 'check_violation';
    END IF;

    -- La séance non encore posée de la semaine du jour choisi, comme pour un
    -- choix dans la liste.
    SELECT o.id_occurrence INTO v_occurrence
      FROM occurrence o
     WHERE o.id_tache = v_tache
       AND o.id_utilisateur = p_utilisateur
       AND lower(o.fenetre) = debut_jour(lundi_de(v_jour))
       AND o.statut IN ('a_placer', 'planifiee')
       AND NOT o.epinglee
     ORDER BY o.creneau NULLS FIRST
     LIMIT 1;

    IF v_occurrence IS NULL THEN
        RAISE EXCEPTION 'Aucune séance à placer cette semaine-là'
              USING ERRCODE = 'no_data_found';
    END IF;

    -- La fenêtre suit le créneau : sans ça, poser une séance hors de la semaine
    -- de son occurrence violerait la contrainte qui exige creneau ⊆ fenetre.
    UPDATE occurrence
       SET creneau  = v_creneau,
           fenetre  = tstzrange(LEAST(lower(fenetre), lower(v_creneau)),
                                GREATEST(upper(fenetre), upper(v_creneau)), '[)'),
           id_lieu  = v_lieu,
           statut   = 'planifiee',
           epinglee = TRUE,
           motif    = 'Posée à la main'
     WHERE id_occurrence = v_occurrence;

    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION caler_seance_sport IS
    'Pose une séance à l''heure exacte demandée, trajet et marges ajoutés
     autour, et l''épingle. Refuse si le bloc tombe sur un cours ou un service
     (SPT-17).';
