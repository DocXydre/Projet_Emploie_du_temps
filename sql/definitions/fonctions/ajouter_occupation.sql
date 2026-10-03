-- -----------------------------------------------------------------------------
-- Poser une occupation à la main                                       (COL-13)
--
-- La saisie manuelle existait déjà par l'API. Cette fonction la rend appelable
-- avec ce dont on dispose depuis un téléphone : un titre, un jour, deux heures.
-- Elle ne fait pas le placement — l'appelant s'en charge, une seule fois.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ajouter_occupation(
    p_utilisateur INTEGER,
    p_libelle     VARCHAR,
    p_debut       TIMESTAMPTZ,
    p_fin         TIMESTAMPTZ,
    -- « autre » par défaut : c'est le type qui échappe à la contrainte de
    -- non-chevauchement, réservée aux cours et aux shifts. Un rendez-vous
    -- pendant un cours doit pouvoir être saisi, quitte à être bizarre — et il
    -- occupe l'agenda de la même façon pour le placement des tâches.
    p_type        VARCHAR DEFAULT 'autre',
    p_lieu        VARCHAR DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_source     INTEGER;
    v_occupation INTEGER;
BEGIN
    IF p_fin <= p_debut THEN
        RAISE EXCEPTION 'La fin doit venir après le début'
              USING ERRCODE = 'check_violation';
    END IF;

    SELECT id_source INTO v_source FROM source WHERE code = 'MANUELLE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source MANUELLE absente' USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO occupation (id_utilisateur, id_source, type, libelle, lieu, periode)
    VALUES (p_utilisateur, v_source, p_type, p_libelle, p_lieu,
            tstzrange(p_debut, p_fin, '[)'))
    RETURNING id_occupation INTO v_occupation;

    RETURN v_occupation;
END $$;

COMMENT ON FUNCTION ajouter_occupation IS
    'Crée une occupation saisie à la main. La contrainte d''exclusion refuse un
     chevauchement avec une occupation existante du même utilisateur (COL-13).';
