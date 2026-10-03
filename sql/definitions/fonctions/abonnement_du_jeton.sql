-- -----------------------------------------------------------------------------
-- Reconnaître un jeton d'abonnement                                     (NOT-8)
--
-- Deux sortes de jetons ouvrent le flux : celui d'un compte, qui donne tout
-- son planning, et celui d'un calendrier composé, qui donne exactement ce qu'on
-- a coché. Une seule fonction les reconnaît, pour que l'URL reste la même.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION abonnement_du_jeton(p_jeton TEXT)
RETURNS TABLE (
    id_calendrier  INTEGER,
    libelle        TEXT,
    id_utilisateur INTEGER,
    pseudo         TEXT,
    role           TEXT,
    personnes      INTEGER[],
    contenus       TEXT[])
LANGUAGE sql STABLE AS $$
    SELECT NULL::INTEGER, 'Planning'::TEXT, u.id_utilisateur, u.pseudo::TEXT,
           u.role::TEXT, ARRAY[u.id_utilisateur],
           ARRAY['cours', 'travail', 'perso', 'taches', 'sport', 'weekends']::TEXT[]
      FROM utilisateur u
     WHERE u.jeton_calendrier = p_jeton AND u.actif

    UNION ALL

    SELECT c.id_calendrier, c.libelle::TEXT, u.id_utilisateur, u.pseudo::TEXT,
           u.role::TEXT, c.personnes, c.contenus
      FROM calendrier c
      JOIN utilisateur u ON u.id_utilisateur = c.id_proprietaire
     WHERE c.jeton = p_jeton AND u.actif;
$$;

COMMENT ON FUNCTION abonnement_du_jeton IS
    'Le jeton d''un compte donne tout son planning ; celui d''un calendrier
     composé donne ce qu''il déclare (NOT-8).';
