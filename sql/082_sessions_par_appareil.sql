-- =============================================================================
-- 082 : une clé par appareil, et plus aucune clé en clair       (CNX-11, CNX-12)
--
-- Rejouable.
--
-- Jusqu'ici, la connexion rendait à chaque iPhone la clé d'API du compte, la
-- même pour tous, gardée en clair dans `utilisateur.cle_api`. Se déconnecter
-- l'effaçait du téléphone sans la révoquer, et une copie de la base donnait
-- toutes les clés.
--
-- Chaque connexion ouvre maintenant une session : une clé à elle, dont la base
-- ne garde que l'empreinte SHA-256, et qui se révoque seule. La clé du compte
-- reste valable, pour les iPhones déjà connectés, les scripts et le bot
-- d'administration, mais elle aussi n'est plus gardée qu'en empreinte : un
-- déclencheur la hache à l'écriture (trg_cle_api_en_empreinte).
-- =============================================================================

CREATE TABLE IF NOT EXISTS session_appareil (
    id_session     SERIAL       PRIMARY KEY,
    id_utilisateur INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur)
                                ON DELETE CASCADE,
    empreinte      CHAR(64)     NOT NULL UNIQUE CHECK (empreinte ~ '^[0-9a-f]{64}$'),
    nom            VARCHAR(80),
    ouverte_le     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    vue_le         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    revoquee_le    TIMESTAMPTZ,
    CHECK (revoquee_le IS NULL OR revoquee_le >= ouverte_le)
);

COMMENT ON TABLE session_appareil IS
    'CNX-11 : une connexion de l''appli, avec sa clé à elle. La base n''en garde que l''empreinte.';
COMMENT ON COLUMN session_appareil.empreinte IS
    'SHA-256 de la clé de la session, en hexadécimal. La clé n''est montrée qu''une fois, à la connexion.';
COMMENT ON COLUMN session_appareil.nom IS
    'Le nom de l''appareil, tel que l''appli le donne à la connexion.';
COMMENT ON COLUMN session_appareil.vue_le IS
    'Le dernier appel avec cette clé, à l''heure près.';
COMMENT ON COLUMN session_appareil.revoquee_le IS
    'CNX-6 : la déconnexion, ou une révocation depuis un autre appareil. La clé ne répond plus.';

CREATE INDEX IF NOT EXISTS session_appareil_id_utilisateur_idx
    ON session_appareil (id_utilisateur);


-- -----------------------------------------------------------------------------
-- La clé du compte, en empreinte                                       (CNX-12)
-- -----------------------------------------------------------------------------
ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS empreinte_cle_api CHAR(64);

UPDATE utilisateur
   SET empreinte_cle_api = encode(sha256(convert_to(cle_api, 'UTF8')), 'hex')
 WHERE cle_api IS NOT NULL;

ALTER TABLE utilisateur ALTER COLUMN cle_api DROP NOT NULL;

UPDATE utilisateur SET cle_api = NULL WHERE cle_api IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS utilisateur_empreinte_cle_api
    ON utilisateur (empreinte_cle_api) WHERE empreinte_cle_api IS NOT NULL;

COMMENT ON COLUMN utilisateur.cle_api IS
    'CNX-12 : toujours vide. Une clé écrite ici est hachée dans empreinte_cle_api, puis effacée.';
COMMENT ON COLUMN utilisateur.empreinte_cle_api IS
    'CNX-12 : SHA-256 de la clé d''API du compte. Elle ouvre l''API comme une session, sans se révoquer.';
