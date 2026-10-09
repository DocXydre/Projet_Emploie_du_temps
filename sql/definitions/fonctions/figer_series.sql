CREATE OR REPLACE FUNCTION figer_series(p_utilisateur INTEGER, p_jour DATE DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_nombre INTEGER;
BEGIN
    UPDATE serie_saisie ss SET figee = TRUE
      FROM occurrence o
     WHERE o.id_occurrence = ss.id_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND NOT ss.figee
       AND jour_de(ss.saisie_le) <= COALESCE(p_jour, jour_de(now()));
    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION figer_series(INTEGER, DATE) IS
    'SAI-8 : fige les séries du jour à la fin de la synthèse du soir. Le coach
     a raisonné dessus, elles ne se corrigent plus. Une série ajoutée ensuite
     reste acceptée (SAI-12).';
