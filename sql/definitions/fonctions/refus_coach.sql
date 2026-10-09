-- -----------------------------------------------------------------------------
-- Un refus du module coach, avec son code stable                       (COA-20)
--
-- Le message est écrit pour être lu, par l'utilisateur comme par le modèle. Le
-- code, lui, est fait pour être testé par l'application : il voyage dans le
-- nom de contrainte de l'erreur, et la table « coach » dit d'où elle vient.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION refus_coach(p_code TEXT, p_message TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%', p_message
          USING ERRCODE = 'check_violation', TABLE = 'coach', CONSTRAINT = p_code;
END $$;

COMMENT ON FUNCTION refus_coach(TEXT, TEXT) IS
    'COA-20 : lève un refus du coach. Le code stable est dans le nom de
     contrainte de l''erreur, le motif lisible dans son message.';
