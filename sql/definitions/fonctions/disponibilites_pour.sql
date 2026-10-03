-- Aiguillage : disponibilités d'une personne, ou de tout le monde.
CREATE OR REPLACE FUNCTION disponibilites_pour(
    p_utilisateur INTEGER,
    p_commun      BOOLEAN,
    p_debut       TIMESTAMPTZ,
    p_fin         TIMESTAMPTZ
) RETURNS SETOF TSTZRANGE LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_commun THEN
        RETURN QUERY SELECT * FROM disponibilites_communes(p_debut, p_fin);
    ELSE
        RETURN QUERY SELECT * FROM disponibilites(p_utilisateur, p_debut, p_fin);
    END IF;
END $$;
