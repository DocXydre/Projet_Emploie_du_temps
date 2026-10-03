-- -----------------------------------------------------------------------------
-- Créer, lister, supprimer                                       (NOT-5, NOT-7)
--
-- Chacun peut composer le calendrier de l'autre : on vit à deux, et un planning
-- que l'autre ne peut pas consulter oblige à le lui redemander tous les jours.
-- Ce qui reste cloisonné, c'est le reste de l'API : un jeton de calendrier ne
-- donne que la lecture d'un planning, jamais le droit d'y toucher (UTI-2).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION creer_calendrier(
    p_proprietaire INTEGER,
    p_libelle      TEXT,
    p_personnes    INTEGER[],
    p_contenus     TEXT[])
RETURNS calendrier LANGUAGE plpgsql AS $$
DECLARE
    v_inconnu INTEGER;
    v_ligne   calendrier;
BEGIN
    IF p_personnes IS NULL OR cardinality(p_personnes) = 0 THEN
        RAISE EXCEPTION 'Il faut au moins une personne dans un calendrier';
    END IF;

    IF p_contenus IS NULL OR cardinality(p_contenus) = 0 THEN
        RAISE EXCEPTION 'Il faut au moins un contenu dans un calendrier';
    END IF;

    SELECT x INTO v_inconnu
      FROM unnest(p_personnes) x
     WHERE NOT EXISTS (SELECT 1 FROM utilisateur u
                        WHERE u.id_utilisateur = x AND u.actif)
     LIMIT 1;

    IF v_inconnu IS NOT NULL THEN
        RAISE EXCEPTION 'Compte % inconnu ou désactivé', v_inconnu;
    END IF;

    INSERT INTO calendrier (libelle, id_proprietaire, personnes, contenus)
    VALUES (btrim(p_libelle), p_proprietaire,
            -- Trié et dédoublonné : « Thomas et Lorette » et « Lorette et
            -- Thomas » sont le même calendrier, et doivent se ressembler.
            ARRAY(SELECT DISTINCT x FROM unnest(p_personnes) x ORDER BY x),
            ARRAY(SELECT DISTINCT c FROM unnest(p_contenus) c ORDER BY c))
    RETURNING * INTO v_ligne;

    RETURN v_ligne;
END $$;

COMMENT ON FUNCTION creer_calendrier IS
    'Crée un calendrier composé et rend son jeton. Refuse un compte inconnu,
     une liste vide de personnes ou de contenus (NOT-5).';
