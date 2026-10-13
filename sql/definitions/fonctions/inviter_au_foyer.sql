-- -----------------------------------------------------------------------------
-- Inviter quelqu'un dans son foyer                                       (FOY-3)
--
-- L'API tire le code et n'en donne ici que l'empreinte : la base ne voit jamais
-- le code. L'invitation vaut 48 heures et réserve une place (FOY-4).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inviter_au_foyer(p_admin INTEGER, p_empreinte TEXT)
RETURNS TABLE (id_invitation INTEGER, expire_le TIMESTAMPTZ)
LANGUAGE plpgsql AS $$
DECLARE
    v_foyer INTEGER := exiger_admin_du_foyer(p_admin);
BEGIN
    -- Deux invitations simultanées ne prennent pas la même dernière place.
    PERFORM 1 FROM foyer f WHERE f.id_foyer = v_foyer FOR UPDATE;
    IF places_libres(v_foyer) < 1 THEN
        RAISE EXCEPTION 'Le foyer est complet : deux personnes au plus pour l''instant'
              USING ERRCODE = 'check_violation';
    END IF;

    RETURN QUERY
    INSERT INTO invitation (id_foyer, empreinte_code, cree_par, expire_le)
    VALUES (v_foyer, p_empreinte, p_admin, now() + INTERVAL '48 hours')
    RETURNING invitation.id_invitation, invitation.expire_le;
END $$;

COMMENT ON FUNCTION inviter_au_foyer(INTEGER, TEXT) IS
    'FOY-3 : une invitation au foyer de l''administrateur, valable 48 heures.';
