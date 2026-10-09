-- =============================================================================
-- 057 : le démarrage du coach dans le bot                          (DEM-1, DEM-2)
--
-- Rejouable.
--
-- Tant que le profil, le dépistage, les lieux ou l'objectif principal manquent
-- (PRO-4, LIE-6, OBJ-8), le bot conduit le compte pas à pas, question par
-- question. Les réponses en cours s'accumulent ici et ne deviennent un profil,
-- un dépistage ou un objectif qu'à la fin de leur bloc, par les routes
-- habituelles : rien ici ne contourne une règle.
-- =============================================================================

CREATE TABLE IF NOT EXISTS demarrage_coach (
    id_utilisateur INTEGER     PRIMARY KEY REFERENCES utilisateur ON DELETE CASCADE,
    -- La question posée, et donc la réponse attendue.
    etape          VARCHAR(30) NOT NULL,
    reponses       JSONB       NOT NULL DEFAULT '{}',
    maj            TIMESTAMPTZ NOT NULL DEFAULT now()
);
