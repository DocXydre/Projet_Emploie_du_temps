-- -----------------------------------------------------------------------------
-- Ce que la base contrôle à la saisie d'une série   (SEC-1, SAI-1, SAI-8, SAI-11)
--
-- Un exercice interdit par une limitation active est refusé, quelle que soit
-- la séance, séance libre comprise : c'est la seule règle de sécurité sans
-- mode souple. Une série renseigne ce que son exercice mesure, et pas le
-- reste. Une série figée ne se corrige ni ne se supprime.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_serie_saisie() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_mesure  TEXT;
    v_libelle TEXT;
    v_motif   TEXT;
BEGIN
    -- Une série figée ne se retouche pas. Supprimer la séance entière emporte
    -- en revanche ses séries : la suppression arrive alors en cascade, depuis
    -- un autre déclencheur, et non d'une requête directe sur la série.
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    IF TG_OP IN ('UPDATE', 'DELETE') AND OLD.figee THEN
        RAISE EXCEPTION 'Cette série est figée : le coach a raisonné dessus'
              USING ERRCODE = 'check_violation', TABLE = 'coach',
                    CONSTRAINT = 'serie_figee';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    SELECT e.mesure, e.libelle INTO v_mesure, v_libelle
      FROM exercice e WHERE e.id_exercice = NEW.id_exercice;

    -- SEC-1.
    SELECT ei.motif INTO v_motif
      FROM exercice_interdit ei
      JOIN limitation l ON l.id_limitation = ei.id_limitation
      JOIN occurrence o ON o.id_utilisateur = l.id_utilisateur
     WHERE o.id_occurrence = NEW.id_occurrence
       AND l.active AND ei.id_exercice = NEW.id_exercice
     LIMIT 1;
    IF v_motif IS NOT NULL THEN
        RAISE EXCEPTION '% est interdit par une limitation : %', v_libelle, v_motif
              USING ERRCODE = 'check_violation', TABLE = 'coach',
                    CONSTRAINT = 'exercice_interdit';
    END IF;

    -- SAI-1.
    IF (v_mesure = 'charge_reps' AND (NEW.repetitions IS NULL
                                      OR NEW.duree_secondes IS NOT NULL
                                      OR NEW.distance_m IS NOT NULL))
       OR (v_mesure = 'duree' AND (NEW.duree_secondes IS NULL
                                   OR NEW.charge_kg IS NOT NULL
                                   OR NEW.repetitions IS NOT NULL))
       OR (v_mesure = 'distance' AND (NEW.distance_m IS NULL
                                      OR NEW.charge_kg IS NOT NULL
                                      OR NEW.repetitions IS NOT NULL)) THEN
        RAISE EXCEPTION '% se saisit en %', v_libelle,
              CASE v_mesure WHEN 'charge_reps' THEN 'charge et répétitions'
                            WHEN 'duree' THEN 'durée'
                            ELSE 'distance' END
              USING ERRCODE = 'check_violation', TABLE = 'coach',
                    CONSTRAINT = 'requete_invalide';
    END IF;

    -- SAI-11 : l'heure vient de l'appareil, jamais du futur.
    IF NEW.saisie_le > now() + INTERVAL '5 minutes' THEN
        RAISE EXCEPTION 'Une série ne se saisit pas dans le futur'
              USING ERRCODE = 'check_violation', TABLE = 'coach',
                    CONSTRAINT = 'requete_invalide';
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION trg_serie_saisie() IS
    'SEC-1, SAI-1, SAI-8, SAI-11 : refuse un exercice interdit, une mesure qui
     n''est pas celle de l''exercice, une heure future, et toute retouche d''une
     série figée.';
