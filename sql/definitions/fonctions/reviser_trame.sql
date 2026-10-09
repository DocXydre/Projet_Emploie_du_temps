CREATE OR REPLACE FUNCTION reviser_trame(
    p_utilisateur INTEGER,
    p_trame       TEXT   DEFAULT NULL,
    p_semaines    JSONB  DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_plan INTEGER;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    SELECT p.id_plan INTO v_plan
      FROM plan p WHERE p.id_utilisateur = p_utilisateur AND p.statut = 'en_cours';
    IF v_plan IS NULL THEN
        PERFORM refus_coach('hors_plan', 'Aucun plan en cours à réviser');
    END IF;

    IF btrim(COALESCE(p_trame, '')) <> '' THEN
        UPDATE plan p SET trame = p_trame WHERE p.id_plan = v_plan;
    END IF;

    -- Le rôle et l'intention d'une semaine se révisent tant qu'elle n'est pas validée.
    UPDATE plan_semaine ps
       SET role      = COALESCE(x.ligne ->> 'role', ps.role),
           intention = COALESCE(x.ligne ->> 'intention', ps.intention)
      FROM jsonb_array_elements(COALESCE(p_semaines, '[]')) AS x(ligne)
     WHERE ps.id_plan = v_plan
       AND ps.lundi = (x.ligne ->> 'lundi')::DATE
       AND ps.validee_le IS NULL;

    PERFORM tracer_coach(p_utilisateur, 'plan', v_plan);
    RETURN v_plan;
END $$;

COMMENT ON FUNCTION reviser_trame(INTEGER, TEXT, JSONB) IS
    'PLN-8 : révise la trame du plan en cours, et le rôle ou l''intention des
     semaines qui ne sont pas encore validées.';
