CREATE OR REPLACE FUNCTION retirer_seance_proposee(p_utilisateur INTEGER, p_occurrence INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    s RECORD;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    SELECT se.etat, se.discipline, se.type_seance, o.statut,
           jour_de(o.debut_seance) AS jour
      INTO s
      FROM seance se JOIN occurrence o ON o.id_occurrence = se.id_occurrence
     WHERE se.id_occurrence = p_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND se.auteur = 'coach';
    IF NOT FOUND OR s.statut NOT IN ('planifiee', 'notifiee') THEN
        PERFORM refus_coach('introuvable', 'Séance du coach introuvable, ou déjà close');
    END IF;
    IF s.etat = 'validee' THEN
        PERFORM refus_coach('seance_validee',
            'Cette séance est validée : dépose un ajustement de retrait');
    END IF;

    DELETE FROM occurrence o WHERE o.id_occurrence = p_occurrence;
    PERFORM tracer_coach(p_utilisateur, 'seance_retiree', p_occurrence,
                         jsonb_build_object('jour', s.jour, 'discipline', s.discipline,
                                            'type_seance', s.type_seance));
END $$;

COMMENT ON FUNCTION retirer_seance_proposee(INTEGER, INTEGER) IS
    'PLN-7 : retire une séance encore proposée. Refuse une séance validée.';
