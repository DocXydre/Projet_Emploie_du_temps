-- -----------------------------------------------------------------------------
-- Le bilan d'une séance : effort, durée, commentaire      (opération C6)
--                                  (SAI-4, SAI-5, SAI-9, SAI-14, LIB-6, LIB-11)
--
-- Enregistrer le bilan compte la séance comme faite, même sans aucune série :
-- la saisie est un service, pas une condition. Un bilan donné après coup
-- s'ajoute à une séance déjà close.
--
-- Pour une séance libre : l'intensité et les groupes se déduisent de ce qui a
-- été fait, la séance du coach de même discipline prévue ce jour-là est close
-- comme remplacée, et la règle des séances dures avertit sans empêcher.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enregistrer_bilan(
    p_utilisateur INTEGER,
    p_occurrence  INTEGER,
    p_effort      INTEGER,
    p_duree       INTEGER,
    p_commentaire TEXT DEFAULT NULL,
    p_cle_client  UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    s               RECORD;
    r               RECORD;
    v_etat          TEXT := 'cree';
    v_avertissements JSONB := '[]';
    v_remplacee     INTEGER;
BEGIN
    SELECT se.libre, se.discipline, o.statut, o.debut_seance,
           jour_de(COALESCE(o.debut_seance, lower(o.fenetre))) AS jour
      INTO s
      FROM seance se JOIN occurrence o ON o.id_occurrence = se.id_occurrence
     WHERE se.id_occurrence = p_occurrence AND o.id_utilisateur = p_utilisateur;
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Séance introuvable');
    END IF;

    INSERT INTO bilan_seance (id_occurrence, effort, duree_minutes, commentaire, cle_client)
    VALUES (p_occurrence, p_effort, p_duree, NULLIF(btrim(p_commentaire), ''), p_cle_client)
    ON CONFLICT (id_occurrence) DO NOTHING;
    IF NOT FOUND THEN
        v_etat := 'existait';
    END IF;

    -- SAI-5 : le bilan vaut « faite ».
    IF s.statut IN ('a_placer', 'planifiee', 'notifiee') THEN
        UPDATE occurrence o SET statut = 'faite', date_faite = now()
         WHERE o.id_occurrence = p_occurrence;
        DELETE FROM notification n
         WHERE n.id_occurrence = p_occurrence AND n.statut = 'a_envoyer' AND n.type = 'rappel';
    END IF;

    IF s.libre AND v_etat = 'cree' THEN
        PERFORM deduire_intensite(p_occurrence);

        -- LIB-6 : la séance du coach de même discipline, prévue ce jour-là, est
        -- remplacée, et non comptée comme pas faite.
        SELECT o.id_occurrence INTO v_remplacee
          FROM occurrence o JOIN seance se ON se.id_occurrence = o.id_occurrence
         WHERE o.id_utilisateur = p_utilisateur
           AND se.auteur = 'coach' AND se.discipline = s.discipline
           AND o.statut IN ('planifiee', 'notifiee')
           AND jour_de(o.debut_seance) = s.jour
         ORDER BY o.debut_seance LIMIT 1;
        IF v_remplacee IS NOT NULL THEN
            UPDATE occurrence o
               SET statut = 'abandonnee', motif = 'Remplacée par une séance libre'
             WHERE o.id_occurrence = v_remplacee;
            UPDATE ajustement a SET statut = 'caduc'
             WHERE a.id_occurrence = v_remplacee AND a.statut = 'propose';
            UPDATE seance se SET id_occurrence_remplacee = v_remplacee
             WHERE se.id_occurrence = p_occurrence;
        END IF;

        -- LIB-11 : la règle des séances dures avertit sans empêcher.
        FOR r IN
            SELECT os.code, os.motif
              FROM seance se,
                   obstacle_sportif(p_utilisateur, COALESCE(s.debut_seance, now()),
                                    se.intensite, se.groupes, NULL, p_occurrence, FALSE) os
             WHERE se.id_occurrence = p_occurrence
        LOOP
            v_avertissements := v_avertissements
                || jsonb_build_object('code', r.code, 'message', r.motif);
        END LOOP;
    END IF;

    RETURN jsonb_build_object('etat', v_etat, 'id_occurrence', p_occurrence,
                              'remplacee', v_remplacee,
                              'avertissements', v_avertissements);
END $$;

COMMENT ON FUNCTION enregistrer_bilan IS
    'Opération C6 : enregistre le bilan et compte la séance comme faite. Pour
     une séance libre, déduit l''intensité, remplace la séance prévue de même
     discipline et avertit sur les séances dures (SAI-4, SAI-5, LIB-6, LIB-11).';
