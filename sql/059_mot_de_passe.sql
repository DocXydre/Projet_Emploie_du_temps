-- -----------------------------------------------------------------------------
-- 059 : se connecter avec un mot de passe                          (CNX-1 à CNX-4)
--
-- L'appli iPhone joint le serveur par Internet (tailscale funnel), sans le
-- client Tailscale. Taper une clé de 48 caractères sur un téléphone n'est pas
-- raisonnable : le pseudo et un mot de passe rendent la clé, gardée ensuite
-- dans le trousseau. Le mot de passe n'est jamais stocké, seulement son
-- empreinte scrypt. Après cinq échecs, le compte refuse les essais quinze
-- minutes : la route est publique.
--
-- Rejouable.
-- -----------------------------------------------------------------------------

ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS mot_de_passe      TEXT;
ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS echecs_connexion  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS bloque_jusqu_a    TIMESTAMPTZ;

COMMENT ON COLUMN utilisateur.mot_de_passe IS
    'CNX-1 : empreinte scrypt du mot de passe (scrypt$n$r$p$sel$empreinte), jamais le
     mot de passe. Vide : la connexion par mot de passe est fermée pour ce compte.';
COMMENT ON COLUMN utilisateur.echecs_connexion IS
    'CNX-3 : échecs de connexion d''affilée. Remis à zéro à la première réussite.';
COMMENT ON COLUMN utilisateur.bloque_jusqu_a IS
    'CNX-3 : après cinq échecs, plus d''essai accepté avant cette heure.';
