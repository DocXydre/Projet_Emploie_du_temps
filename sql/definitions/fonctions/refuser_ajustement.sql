CREATE OR REPLACE FUNCTION refuser_ajustement(p_utilisateur INTEGER, p_ajustement INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_occurrence INTEGER;
BEGIN
    UPDATE ajustement a SET statut = 'refuse', date_reponse = now()
      FROM occurrence o
     WHERE o.id_occurrence = a.id_occurrence
       AND a.id_ajustement = p_ajustement
       AND o.id_utilisateur = p_utilisateur
       AND a.statut = 'propose'
    RETURNING a.id_occurrence INTO v_occurrence;
    IF v_occurrence IS NULL THEN
        PERFORM refus_coach('introuvable', 'Ajustement introuvable, ou déjà traité');
    END IF;
    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION refuser_ajustement(INTEGER, INTEGER) IS
    'PLN-19 : l''utilisateur garde la séance telle que validée. Rien ne change,
     même pour un allègement.';
