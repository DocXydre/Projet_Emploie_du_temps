-- -----------------------------------------------------------------------------
-- Le coach dépose un ajustement sur une séance validée       (opération C14)
--                                                           (PLN-18, PLN-19)
--
-- Le coach ne modifie ni ne retire seul une séance validée. Il dépose ce qu'il
-- voudrait mettre à la place, avec son motif, et l'utilisateur tranche.
--
-- La nouvelle version est vérifiée dès le dépôt, placement et sécurité en mode
-- strict. Un allègement ne peut que réduire : sans ce contrôle, le mot
-- « alléger » suffirait à faire passer n'importe quoi quand l'utilisateur ne
-- répond pas.
--
-- p_contenu, selon la nature :
--   alleger   duree_minutes, intensite, exercices (les mêmes, en moins)
--   modifier  type_seance, intensite, duree_minutes, consigne, exercices
--   deplacer  jour, heure_min, heure_max, id_lieu
--   retirer   rien
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION proposer_ajustement(
    p_utilisateur INTEGER,
    p_occurrence  INTEGER,
    p_nature      VARCHAR,
    p_contenu     JSONB,
    p_motif       TEXT
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    s            RECORD;
    r            RECORD;
    x            RECORD;
    v_rang       JSONB := '{"legere": 1, "moderee": 2, "dure": 3}';
    v_intensite  VARCHAR;
    v_duree      INTEGER;
    v_groupes    TEXT[];
    v_ids        INTEGER[];
    v_ajustement INTEGER;
    v_jour       DATE;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    SELECT se.*, o.statut, o.id_lieu, o.debut_seance, jour_de(o.debut_seance) AS jour
      INTO s
      FROM seance se JOIN occurrence o ON o.id_occurrence = se.id_occurrence
     WHERE se.id_occurrence = p_occurrence AND o.id_utilisateur = p_utilisateur;
    IF NOT FOUND OR s.statut NOT IN ('planifiee', 'notifiee') THEN
        PERFORM refus_coach('introuvable', 'Séance introuvable, ou déjà close');
    END IF;
    IF s.etat <> 'validee' OR s.libre THEN
        PERFORM refus_coach('requete_invalide',
            'Un ajustement porte sur une séance validée du plan. Une séance '
            || 'proposée se modifie directement');
    END IF;
    IF s.debut_seance <= now() THEN
        PERFORM refus_coach('requete_invalide', 'Cette séance a déjà commencé');
    END IF;
    IF en_pause(p_utilisateur, s.jour) THEN
        PERFORM refus_coach('coach_en_pause', 'Le coach est en pause ce jour-là');
    END IF;
    IF EXISTS (SELECT 1 FROM ajustement a
                WHERE a.id_occurrence = p_occurrence AND a.statut = 'propose') THEN
        PERFORM refus_coach('requete_invalide',
            'Un ajustement attend déjà une réponse sur cette séance');
    END IF;
    IF p_nature NOT IN ('alleger', 'modifier', 'deplacer', 'retirer') THEN
        PERFORM refus_coach('requete_invalide', 'Nature d''ajustement inconnue');
    END IF;
    IF btrim(COALESCE(p_motif, '')) = '' THEN
        PERFORM refus_coach('requete_invalide', 'Un ajustement donne son motif');
    END IF;
    IF p_nature <> 'retirer'
       AND (p_contenu IS NULL OR jsonb_typeof(p_contenu) <> 'object' OR p_contenu = '{}') THEN
        PERFORM refus_coach('requete_invalide',
            'Cet ajustement doit dire ce qu''il met à la place');
    END IF;

    v_intensite := COALESCE(p_contenu ->> 'intensite', s.intensite);
    v_duree     := COALESCE((p_contenu ->> 'duree_minutes')::INTEGER, s.duree_minutes);

    IF p_nature = 'alleger' THEN
        IF (v_rang ->> v_intensite)::INTEGER > (v_rang ->> s.intensite)::INTEGER THEN
            PERFORM refus_coach('requete_invalide',
                'Un allègement ne peut pas augmenter l''intensité');
        END IF;
        IF v_duree > s.duree_minutes THEN
            PERFORM refus_coach('requete_invalide',
                'Un allègement ne peut pas allonger la séance');
        END IF;
        FOR x IN
            SELECT l.ligne ->> 'code' AS code, e.libelle,
                   (l.ligne ->> 'series')::INTEGER AS series,
                   (l.ligne ->> 'charge_kg')::NUMERIC AS charge,
                   (l.ligne ->> 'duree_secondes')::INTEGER AS duree,
                   (l.ligne ->> 'distance_m')::INTEGER AS distance,
                   (l.ligne ->> 'repetitions_max')::INTEGER AS reps,
                   p.series AS p_series, p.charge_kg AS p_charge,
                   p.duree_secondes AS p_duree, p.distance_m AS p_distance,
                   p.repetitions_max AS p_reps, p.id_seance_exercice
              FROM jsonb_array_elements(COALESCE(p_contenu -> 'exercices', '[]')) AS l(ligne)
              LEFT JOIN exercice e ON e.code = l.ligne ->> 'code'
              LEFT JOIN LATERAL (SELECT se.* FROM seance_exercice se
                                  WHERE se.id_occurrence = p_occurrence
                                    AND se.id_exercice = e.id_exercice
                                  ORDER BY se.rang LIMIT 1) p ON TRUE
        LOOP
            IF x.id_seance_exercice IS NULL THEN
                PERFORM refus_coach('requete_invalide',
                    format('Un allègement n''ajoute pas d''exercice : %s n''est pas '
                           || 'dans la séance', COALESCE(x.libelle, x.code)));
            END IF;
            IF COALESCE(x.series, 1) > x.p_series
               OR x.charge > COALESCE(x.p_charge, x.charge)
               OR (x.charge IS NOT NULL AND x.p_charge IS NULL)
               OR x.duree > COALESCE(x.p_duree, x.duree)
               OR x.distance > COALESCE(x.p_distance, x.distance)
               OR x.reps > COALESCE(x.p_reps, x.reps) THEN
                PERFORM refus_coach('requete_invalide',
                    format('Un allègement ne peut que réduire : %s augmente', x.libelle));
            END IF;
        END LOOP;
    END IF;

    IF p_nature IN ('alleger', 'modifier') THEN
        -- La version proposée passe les mêmes contrôles qu'une proposition.
        IF p_contenu ? 'exercices' THEN
            v_ids := verifier_exercices(p_utilisateur, s.discipline,
                                        p_contenu -> 'exercices', s.jour);
            IF cardinality(v_ids) = 0 THEN
                PERFORM refus_coach('requete_invalide',
                    'Une séance validée ne redevient pas une esquisse');
            END IF;
        END IF;
        IF s.discipline <> 'musculation' THEN
            v_groupes := ARRAY['cardio'];
        ELSIF v_ids IS NOT NULL THEN
            SELECT array_agg(DISTINCT e.groupe_principal) INTO v_groupes
              FROM exercice e WHERE e.id_exercice = ANY (v_ids);
        ELSE
            v_groupes := s.groupes;
        END IF;

        SELECT os.code, os.motif INTO r
          FROM obstacle_sportif(p_utilisateur, s.debut_seance, v_intensite, v_groupes,
                                v_ids, p_occurrence, TRUE) os
         WHERE os.bloquant LIMIT 1;
        IF FOUND THEN
            PERFORM refus_coach(r.code, r.motif);
        END IF;

        IF v_duree > s.duree_minutes THEN
            r := NULL;
            SELECT obstacle_seance_coach(p_utilisateur, s.id_lieu, s.debut_seance, v_duree,
                                         s.discipline, p_occurrence, TRUE) AS motif INTO r;
            IF r.motif IS NOT NULL THEN
                PERFORM refus_coach('creneau_pris', r.motif);
            END IF;
        END IF;
    ELSIF p_nature = 'deplacer' THEN
        v_jour := COALESCE((p_contenu ->> 'jour')::DATE, s.jour);
        IF en_pause(p_utilisateur, v_jour) THEN
            PERFORM refus_coach('coach_en_pause', 'Le coach est en pause ce jour-là');
        END IF;
        IF NOT (p_contenu ? 'heure_min' AND p_contenu ? 'heure_max') THEN
            PERFORM refus_coach('requete_invalide',
                'Un déplacement donne un jour et une plage d''heures');
        END IF;
        PERFORM chercher_debut_seance(
            p_utilisateur,
            CASE WHEN p_contenu ? 'id_lieu'
                 THEN lieu_de_discipline(p_utilisateur, s.discipline,
                                         (p_contenu ->> 'id_lieu')::INTEGER)
                 ELSE s.id_lieu END,
            v_jour, (p_contenu ->> 'heure_min')::TIME, (p_contenu ->> 'heure_max')::TIME,
            s.duree_minutes, s.discipline, s.intensite, s.groupes, p_occurrence);
    END IF;

    INSERT INTO ajustement (id_occurrence, nature, contenu, motif)
    VALUES (p_occurrence, p_nature,
            CASE WHEN p_nature = 'retirer' THEN NULL ELSE p_contenu END, p_motif)
    RETURNING id_ajustement INTO v_ajustement;

    PERFORM tracer_coach(p_utilisateur, 'ajustement', v_ajustement);
    RETURN v_ajustement;
END $$;

COMMENT ON FUNCTION proposer_ajustement(INTEGER, INTEGER, VARCHAR, JSONB, TEXT) IS
    'Opération C14 : dépose un ajustement sur une séance validée, vérifié en
     mode strict. Un allègement ne peut que réduire (PLN-18, PLN-19).';
