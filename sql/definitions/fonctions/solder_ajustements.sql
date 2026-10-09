-- -----------------------------------------------------------------------------
-- Les ajustements restés sans réponse quand la séance commence        (PLN-19)
--
-- Le silence ne peut qu'alléger : un allègement ou un retrait s'applique, et
-- l'utilisateur en est prévenu. Une modification ou un déplacement devient
-- caduc. Un ajustement qui ne passe plus ses contrôles devient caduc aussi.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION solder_ajustements() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    a        RECORD;
    v_soldes INTEGER := 0;
BEGIN
    FOR a IN
        SELECT aj.id_ajustement, aj.nature, aj.motif, o.id_utilisateur, o.id_occurrence
          FROM ajustement aj
          JOIN occurrence o ON o.id_occurrence = aj.id_occurrence
         WHERE aj.statut = 'propose'
           AND (o.debut_seance <= now() OR o.statut NOT IN ('planifiee', 'notifiee'))
    LOOP
        IF a.nature IN ('alleger', 'retirer') THEN
            BEGIN
                PERFORM appliquer_ajustement(a.id_ajustement);
                UPDATE ajustement SET statut = 'accepte', date_reponse = now()
                 WHERE id_ajustement = a.id_ajustement;
                INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
                VALUES (a.id_utilisateur, a.id_occurrence, 'coach',
                        format('Sans réponse de ta part, j''ai %s la séance qui commence. '
                               || 'Motif : %s',
                               CASE a.nature WHEN 'alleger' THEN 'allégé' ELSE 'retiré' END,
                               a.motif));
            EXCEPTION WHEN check_violation THEN
                UPDATE ajustement SET statut = 'caduc' WHERE id_ajustement = a.id_ajustement;
            END;
        ELSE
            UPDATE ajustement SET statut = 'caduc' WHERE id_ajustement = a.id_ajustement;
        END IF;
        v_soldes := v_soldes + 1;
    END LOOP;
    RETURN v_soldes;
END $$;

COMMENT ON FUNCTION solder_ajustements() IS
    'PLN-19 : au début d''une séance, applique un allègement ou un retrait
     resté sans réponse, et rend caduc tout autre ajustement en attente.';
