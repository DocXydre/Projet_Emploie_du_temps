-- Libre au même moment, au sens strict : ni cours, ni service, ni séance déjà
-- choisie ce jour-là. Le lieu compte, puisqu'il porte la durée et le trajet.
CREATE OR REPLACE FUNCTION seance_possible_a_deux(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM partenaires_sport(p_utilisateur) p
         WHERE obstacle_seance(p, p_lieu, p_debut, NULL, TRUE) IS NULL);
$$;

COMMENT ON FUNCTION seance_possible_a_deux IS
    'Vrai si au moins une autre personne tient ce créneau, au même endroit et
     à la même heure (SPT-30).';
