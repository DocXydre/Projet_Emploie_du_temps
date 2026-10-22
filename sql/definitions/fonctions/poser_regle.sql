-- -----------------------------------------------------------------------------
-- Poser une règle sur une tâche                         (CND-1, CND-11, RAP-3)
--
-- Les briques arrivent en JSON : `[{nature, pour_qui, id_utilisateur,
-- parametres}]`. La fréquence aussi : `{"min": 2, "max": 3}` ou
-- `{"fois": 1, "par": "mois"}`. La base vérifie tout, écrit la traduction, et
-- pose elle-même le rappel « règle impossible » (RAP-3).
--
-- Les droits (FOY-6) se vérifient à la route, comme pour les autres gestes sur
-- les tâches ; une demande acceptée passe par la même route (ACC-4).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION poser_regle(p_tache        INTEGER,
                                       p_acteur       INTEGER,
                                       p_briques      JSONB,
                                       p_phrase       TEXT      DEFAULT NULL,
                                       p_validite     DATERANGE DEFAULT NULL,
                                       p_chaque_annee BOOLEAN   DEFAULT FALSE,
                                       p_frequence    JSONB     DEFAULT NULL,
                                       p_id_demande   BIGINT    DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_motif TEXT;
    v_regle INTEGER;
BEGIN
    v_motif := motif_regle(p_tache, p_briques, p_validite, COALESCE(p_chaque_annee, FALSE),
                           p_frequence);
    IF v_motif IS NOT NULL THEN
        RAISE EXCEPTION '%', v_motif USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO regle_tache (id_tache, phrase, traduction, validite, chaque_annee,
                             periodicite_min_jours, periodicite_max_jours,
                             rythme_nombre, rythme_periode, posee_par, id_demande)
    VALUES (p_tache,
            NULLIF(btrim(p_phrase), ''),
            traduire_regle(p_briques, p_validite, COALESCE(p_chaque_annee, FALSE), p_frequence),
            p_validite, COALESCE(p_chaque_annee, FALSE),
            (p_frequence ->> 'min')::INTEGER, (p_frequence ->> 'max')::INTEGER,
            (p_frequence ->> 'fois')::SMALLINT, p_frequence ->> 'par',
            p_acteur, p_id_demande)
    RETURNING id_regle_tache INTO v_regle;

    PERFORM ecrire_briques(v_regle, p_briques);

    -- RAP-3 : toute règle active a son rappel « impossible », posé par la base.
    INSERT INTO rappel_hal (id_regle_tache, id_tache, nature, evenement, consigne, pose_par)
    VALUES (v_regle, p_tache, 'evenement', 'impossible',
            'Aucun jour ne tient cette règle dans sa période : proposer le jour qui s''en approche le plus, ou la période suivante (CND-12).',
            'base');

    RETURN v_regle;
END $$;

COMMENT ON FUNCTION poser_regle(INTEGER, INTEGER, JSONB, TEXT, DATERANGE, BOOLEAN, JSONB, BIGINT) IS
    'CND-1, CND-11 : pose une règle de briques sur une tâche, avec sa traduction et son rappel « impossible ». Rend son numéro.';
