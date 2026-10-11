-- -----------------------------------------------------------------------------
-- Les exercices d'une séance du coach sont-ils permis ?  (EXO-5, PLN-20, PLN-21)
--
-- Rend leurs identifiants, dans l'ordre. Refuse un code inconnu ou désactivé,
-- un exercice d'une autre discipline, et une charge fixée là où le coach n'a
-- pas le droit d'en fixer : pendant la semaine de calibrage, ou sur un
-- exercice que l'utilisateur n'a jamais saisi.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION verifier_exercices(
    p_utilisateur INTEGER,
    p_discipline  VARCHAR,
    p_exercices   JSONB,
    p_jour        DATE
) RETURNS INTEGER[] LANGUAGE plpgsql STABLE AS $$
DECLARE
    x        RECORD;
    v_ids    INTEGER[] := '{}';
    v_role   TEXT;
BEGIN
    IF p_exercices IS NULL OR jsonb_typeof(p_exercices) <> 'array' THEN
        RETURN v_ids;
    END IF;

    SELECT ps.role INTO v_role
      FROM plan p JOIN plan_semaine ps ON ps.id_plan = p.id_plan
     WHERE p.id_utilisateur = p_utilisateur AND p.statut = 'en_cours'
       AND ps.lundi = lundi_de(p_jour);

    FOR x IN
        SELECT l.rang, l.ligne ->> 'code' AS code,
               (l.ligne ->> 'charge_kg')::NUMERIC AS charge,
               e.id_exercice, e.libelle, e.discipline, e.actif
          FROM jsonb_array_elements(p_exercices) WITH ORDINALITY AS l(ligne, rang)
          LEFT JOIN exercice e ON e.code = l.ligne ->> 'code'
         ORDER BY l.rang
    LOOP
        IF x.id_exercice IS NULL OR NOT x.actif THEN
            PERFORM refus_coach('exercice_inconnu',
                format('Exercice inconnu ou désactivé au catalogue : %s', COALESCE(x.code, '?')));
        END IF;
        IF (p_discipline = 'musculation') <> (x.discipline = 'musculation') THEN
            PERFORM refus_coach('exercice_inconnu',
                format('%s n''est pas un exercice de %s', x.libelle, p_discipline));
        END IF;
        IF x.charge IS NOT NULL AND p_discipline = 'musculation' THEN
            IF v_role = 'calibrage' THEN
                PERFORM refus_coach('charge_non_permise',
                    format('Semaine de calibrage : pas de charge fixée sur %s, '
                           || 'l''utilisateur la choisit au ressenti', x.libelle));
            END IF;
            IF NOT EXISTS (SELECT 1 FROM serie_saisie ss
                             JOIN occurrence o ON o.id_occurrence = ss.id_occurrence
                            WHERE o.id_utilisateur = p_utilisateur
                              AND ss.id_exercice = x.id_exercice) THEN
                PERFORM refus_coach('charge_non_permise',
                    format('%s n''a jamais été saisi : la première fois se fait au '
                           || 'ressenti, sans charge fixée', x.libelle));
            END IF;
        END IF;
        v_ids := v_ids || x.id_exercice;
    END LOOP;
    RETURN v_ids;
END $$;

COMMENT ON FUNCTION verifier_exercices(INTEGER, VARCHAR, JSONB, DATE) IS
    'EXO-5, PLN-20, PLN-21 : vérifie les exercices d''une séance du coach et
     rend leurs identifiants. Code inconnu, mauvaise discipline ou charge non
     permise : refus avec son motif.';
