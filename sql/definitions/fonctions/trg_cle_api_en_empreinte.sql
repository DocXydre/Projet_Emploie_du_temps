-- -----------------------------------------------------------------------------
-- La clé du compte n'est jamais gardée en clair                        (CNX-12)
--
-- Un INSERT ou un UPDATE peut toujours écrire `cle_api`, comme le font la
-- création des comptes, les scripts et les tests : la clé est hachée dans
-- `empreinte_cle_api`, et la colonne repart vide.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_cle_api_en_empreinte()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.cle_api IS NOT NULL THEN
        -- La contrainte de longueur ne verrait que la colonne vidée.
        IF length(NEW.cle_api) < 32 THEN
            RAISE EXCEPTION 'Une clé d''API fait au moins 32 caractères'
                  USING ERRCODE = 'check_violation';
        END IF;
        NEW.empreinte_cle_api := encode(sha256(convert_to(NEW.cle_api, 'UTF8')), 'hex');
        NEW.cle_api := NULL;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION trg_cle_api_en_empreinte() IS
    'CNX-12 : hache la clé d''API écrite dans utilisateur.cle_api, et vide la colonne.';
