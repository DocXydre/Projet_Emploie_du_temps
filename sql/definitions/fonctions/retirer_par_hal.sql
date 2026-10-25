-- -----------------------------------------------------------------------------
-- HAL retire une prévision que la description exclut                  (VER-10)
--
-- Seulement une prévision : ni ce qui est annoncé, ni ce qui est fait, ni ce
-- qu'on a posé ou épinglé à la main. Sans notification derrière elle, elle
-- disparaît ; sinon elle est close, avec le motif de HAL.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retirer_par_hal(p_occurrence INTEGER, p_motif TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    o occurrence%ROWTYPE;
BEGIN
    SELECT * INTO o FROM occurrence WHERE id_occurrence = p_occurrence;
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Cette occurrence n''existe pas');
    END IF;
    IF o.statut NOT IN ('a_placer', 'planifiee') OR o.origine = 'manuelle'
       OR o.epinglee_par = 'admin'
       OR NOT EXISTS (SELECT 1 FROM tache t WHERE t.id_tache = o.id_tache AND t.id_type_tache IS NOT NULL) THEN
        PERFORM refus_coach('non_retirable',
            'Seule une prévision se retire : pas ce qui est annoncé, fait, ou posé à la main');
    END IF;
    IF length(btrim(COALESCE(p_motif, ''))) < 3 THEN
        PERFORM refus_coach('requete_invalide', 'Le motif dit pourquoi elle n''a pas lieu d''être');
    END IF;

    PERFORM set_config('planif.par_hal', '1', TRUE);
    IF EXISTS (SELECT 1 FROM notification n WHERE n.id_occurrence = p_occurrence) THEN
        UPDATE occurrence SET statut = 'abandonnee', creneau = NULL, motif = btrim(p_motif)
         WHERE id_occurrence = p_occurrence;
    ELSE
        DELETE FROM occurrence WHERE id_occurrence = p_occurrence;
    END IF;
    PERFORM set_config('planif.par_hal', '', TRUE);
END $$;

COMMENT ON FUNCTION retirer_par_hal(INTEGER, TEXT) IS
    'VER-10 : HAL retire une prévision qu''une description exclut.';
