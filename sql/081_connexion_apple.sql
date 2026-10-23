-- =============================================================================
-- 081 : se connecter avec Apple                                   (CNX-7 à CNX-9)
--
-- Rejouable.
--
-- « Se connecter avec Apple » rend à l'appli un jeton signé par Apple, qui
-- porte un identifiant stable de la personne pour cette appli (`sub`). Le
-- serveur le relie à un compte : la première fois avec le pseudo et le mot de
-- passe, ou en rejoignant le foyer. Ensuite, Apple suffit.
-- =============================================================================

ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS identifiant_apple TEXT;

-- CNX-8 : un identifiant Apple ouvre un seul compte.
CREATE UNIQUE INDEX IF NOT EXISTS utilisateur_identifiant_apple
    ON utilisateur (identifiant_apple) WHERE identifiant_apple IS NOT NULL;

COMMENT ON COLUMN utilisateur.identifiant_apple IS
    'CNX-7 : le « sub » du jeton de « Se connecter avec Apple ». Il ouvre le compte sans mot de passe.';
