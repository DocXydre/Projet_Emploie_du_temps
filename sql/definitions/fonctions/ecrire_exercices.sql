CREATE OR REPLACE FUNCTION ecrire_exercices(p_occurrence INTEGER, p_exercices JSONB)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_nombre INTEGER;
BEGIN
    DELETE FROM seance_exercice se WHERE se.id_occurrence = p_occurrence;

    INSERT INTO seance_exercice (id_occurrence, rang, id_exercice, series,
                                 repetitions_min, repetitions_max, charge_kg,
                                 duree_secondes, distance_m, repos_secondes,
                                 marge_repetitions, cible, consigne)
    SELECT p_occurrence, l.rang::SMALLINT, e.id_exercice,
           COALESCE((l.ligne ->> 'series')::SMALLINT, 1),
           (l.ligne ->> 'repetitions_min')::SMALLINT,
           (l.ligne ->> 'repetitions_max')::SMALLINT,
           (l.ligne ->> 'charge_kg')::NUMERIC,
           (l.ligne ->> 'duree_secondes')::INTEGER,
           (l.ligne ->> 'distance_m')::INTEGER,
           (l.ligne ->> 'repos_secondes')::SMALLINT,
           (l.ligne ->> 'marge_repetitions')::SMALLINT,
           left(l.ligne ->> 'cible', 60),
           l.ligne ->> 'consigne'
      FROM jsonb_array_elements(COALESCE(p_exercices, '[]'))
               WITH ORDINALITY AS l(ligne, rang)
      JOIN exercice e ON e.code = l.ligne ->> 'code';

    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION ecrire_exercices(INTEGER, JSONB) IS
    'PLN-3 : remplace les exercices prévus d''une séance par la liste donnée,
     dans son ordre. Une liste vide en refait une esquisse (PLN-22).';
