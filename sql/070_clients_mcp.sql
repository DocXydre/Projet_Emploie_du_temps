-- =============================================================================
-- 070 : les clients MCP                                    (MCP-2, MCP-10, MCP-12)
--
-- Rejouable.
--
-- HAL devient un serveur MCP : Claude Code, Gemini CLI ou Claude Desktop le
-- lisent depuis la machine de l'utilisateur (partie F). Chaque client a sa clé,
-- qui n'ouvre que /mcp et se révoque seule, sans toucher à la clé de l'appli.
-- Seule l'empreinte de la clé est gardée : la clé n'est montrée qu'une fois.
--
-- Une session regroupe ce qu'un client a fait d'une traite : son numéro
-- d'opération, ses outils, leur nombre. Une conversation tenue dans le client
-- se termine par un résumé, rangé dans les échanges sous l'auteur « client » et
-- le moment « externe » : HAL le relit ensuite dans l'appli (CAR-7).
-- =============================================================================

-- MCP-2 : une clé par client, nommée, révocable.
CREATE TABLE IF NOT EXISTS cle_mcp (
    id_cle         INTEGER     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur ON DELETE CASCADE,
    nom            VARCHAR(40) NOT NULL CHECK (btrim(nom) <> ''),
    empreinte      CHAR(64)    NOT NULL UNIQUE,
    cree_le        TIMESTAMPTZ NOT NULL DEFAULT now(),
    dernier_usage  TIMESTAMPTZ,
    revoquee_le    TIMESTAMPTZ
);
-- Deux clés vivantes d'un même compte ne portent pas le même nom : sinon
-- Réglages ne saurait pas dire laquelle révoquer. Une clé révoquée libère le sien.
CREATE UNIQUE INDEX IF NOT EXISTS cle_mcp_nom_unique
    ON cle_mcp (id_utilisateur, lower(nom)) WHERE revoquee_le IS NULL;

-- MCP-10 : ce qu'un client a fait d'une traite.
CREATE TABLE IF NOT EXISTS session_mcp (
    id_session    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cle        INTEGER     NOT NULL REFERENCES cle_mcp ON DELETE CASCADE,
    client        VARCHAR(60) NOT NULL CHECK (btrim(client) <> ''),
    operation     TEXT        NOT NULL,
    debut         TIMESTAMPTZ NOT NULL DEFAULT now(),
    dernier_appel TIMESTAMPTZ NOT NULL DEFAULT now(),
    appels        INTEGER     NOT NULL DEFAULT 0 CHECK (appels >= 0),
    deroule       JSONB       NOT NULL DEFAULT '[]'
        CONSTRAINT session_mcp_deroule_liste CHECK (jsonb_typeof(deroule) = 'array')
);
CREATE INDEX IF NOT EXISTS session_mcp_par_cle ON session_mcp (id_cle, dernier_appel DESC);

-- MCP-12 : le résumé d'une conversation tenue dans un client.
ALTER TABLE echange ADD COLUMN IF NOT EXISTS client VARCHAR(60);

ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_auteur_check;
ALTER TABLE echange ADD CONSTRAINT echange_auteur_check
    CHECK (auteur IN ('utilisateur', 'coach', 'systeme', 'client'));

ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_moment_check;
ALTER TABLE echange ADD CONSTRAINT echange_moment_check
    CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan',
                      'signalement', 'chat', 'changement', 'externe'));

-- Un résumé de client dit de quel client il vient, et reste un résumé : il
-- entre dans les dix derniers échanges rendus à HAL à chaque appel.
ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_client_coherent;
ALTER TABLE echange ADD CONSTRAINT echange_client_coherent
    CHECK ((auteur = 'client') = (client IS NOT NULL)
           AND (auteur <> 'client' OR (moment = 'externe' AND char_length(contenu) <= 2000)));
