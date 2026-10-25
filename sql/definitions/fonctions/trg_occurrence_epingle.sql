-- -----------------------------------------------------------------------------
-- Qui a épinglé                                                         (VER-1)
--
-- L'épingle a deux auteurs : HAL, pour ce qu'il place selon une description,
-- et la main, celle de l'administrateur ou de l'utilisateur pour une séance
-- posée à son heure. Un chemin qui épingle sans le dire épingle à la main ;
-- désépingler efface l'auteur.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occurrence_epingle() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.epinglee AND NEW.epinglee_par IS NULL THEN
        NEW.epinglee_par := 'admin';
    ELSIF NOT NEW.epinglee THEN
        NEW.epinglee_par := NULL;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION trg_occurrence_epingle() IS
    'VER-1 : une occurrence épinglée dit par qui ; sans auteur, c''est à la main.';
