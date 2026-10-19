-- -----------------------------------------------------------------------------
-- Les demandes restées sans réponse expirent                           (ACC-8)
--
-- Appelée au report de 0h05. Une demande expirée ne s'accepte plus : elle se
-- redemande, sur un planning qui a pu bouger.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION expirer_demandes()
RETURNS INTEGER LANGUAGE sql AS $$
    WITH expirees AS (
        UPDATE demande SET etat = 'expiree', decidee_le = now()
         WHERE etat = 'en_attente' AND expire_le <= now()
        RETURNING 1
    )
    SELECT count(*)::INTEGER FROM expirees;
$$;

COMMENT ON FUNCTION expirer_demandes() IS
    'ACC-8 : passe à « expiree » les demandes restées sans réponse.';
