CREATE OR REPLACE FUNCTION accepter_ajustement(p_utilisateur INTEGER, p_ajustement INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_occurrence INTEGER;
BEGIN
    SELECT a.id_occurrence INTO v_occurrence
      FROM ajustement a JOIN occurrence o ON o.id_occurrence = a.id_occurrence
     WHERE a.id_ajustement = p_ajustement
       AND o.id_utilisateur = p_utilisateur
       AND a.statut = 'propose'
       FOR UPDATE OF a;
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Ajustement introuvable, ou déjà traité');
    END IF;

    PERFORM appliquer_ajustement(p_ajustement);
    UPDATE ajustement a SET statut = 'accepte', date_reponse = now()
     WHERE a.id_ajustement = p_ajustement;
    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION accepter_ajustement(INTEGER, INTEGER) IS
    'PLN-19 : l''utilisateur accepte la version du coach. Les contrôles sont
     rejoués et peuvent refuser si l''emploi du temps a changé depuis.';
