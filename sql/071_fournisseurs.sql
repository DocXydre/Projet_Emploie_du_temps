-- =============================================================================
-- 071 : les fournisseurs du modèle                              (FOU-1 à FOU-19)
--
-- Rejouable.
--
-- Chaque compte range ses fournisseurs : son abonnement Claude, par Claude
-- Code, puis l'API, en secours, sous un plafond mensuel. Un appel essaie le
-- premier disponible et passe au suivant quand une limite d'usage est
-- atteinte. Un compte sans fournisseur garde la clé d'API du serveur, comme
-- avant.
--
-- Les secrets (jeton d'abonnement, clé d'API) sont chiffrés par l'API avec une
-- clé qui vit dans .env, jamais dans la base : une copie de la base ne donne
-- aucun abonnement.
--
-- Les tarifs servent au plafond de l'API (FOU-7) : la dépense du mois se
-- calcule sur les tokens des appels passés par l'API. Ils viennent de la
-- grille d'Anthropic au 6 octobre 2026 ; l'écriture en cache y est comptée à
-- 1,25 fois l'entrée, la règle de la grille. Un modèle absent de la table se
-- compte au tarif le plus cher.
-- =============================================================================

-- FOU-1 : les fournisseurs d'un compte, rangés.
CREATE TABLE IF NOT EXISTS fournisseur_modele (
    id_fournisseur  INTEGER       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur  INTEGER       NOT NULL REFERENCES utilisateur ON DELETE CASCADE,
    type            VARCHAR(12)   NOT NULL
        CHECK (type IN ('claude_code', 'api', 'gemini_cli')),
    rang            SMALLINT      NOT NULL CHECK (rang > 0),
    -- FOU-3 : chiffré par l'API. Vide pour l'API de l'administrateur du
    -- serveur seul : c'est alors la clé du serveur (.env) qui sert.
    secret          BYTEA,
    secret_fin      CHAR(4),
    etat            VARCHAR(14)   NOT NULL DEFAULT 'actif'
        CHECK (etat IN ('actif', 'de_cote', 'a_reconnecter', 'coupe')),
    de_cote_jusqu_a TIMESTAMPTZ,
    motif           TEXT,
    plafond_mensuel NUMERIC(7,2)  CHECK (plafond_mensuel > 0),
    dernier_usage   TIMESTAMPTZ,
    cree_le         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT fournisseur_un_par_type UNIQUE (id_utilisateur, type),
    CONSTRAINT fournisseur_un_par_rang UNIQUE (id_utilisateur, rang)
        DEFERRABLE INITIALLY DEFERRED,
    -- FOU-7 : seule l'API a un plafond.
    CONSTRAINT fournisseur_plafond_api CHECK (type = 'api' OR plafond_mensuel IS NULL),
    -- Un abonnement a toujours son jeton ; seule l'API peut prendre celle du serveur.
    CONSTRAINT fournisseur_secret_requis CHECK (type = 'api' OR secret IS NOT NULL),
    CONSTRAINT fournisseur_secret_fin CHECK ((secret IS NULL) = (secret_fin IS NULL)),
    -- FOU-5 : de côté, jusqu'à une heure dite.
    CONSTRAINT fournisseur_de_cote_date
        CHECK ((etat = 'de_cote') = (de_cote_jusqu_a IS NOT NULL))
);

-- FOU-7 : la grille, en dollars par million de tokens.
CREATE TABLE IF NOT EXISTS tarif_modele (
    modele      VARCHAR(60)  PRIMARY KEY,
    entree      NUMERIC(8,4) NOT NULL CHECK (entree >= 0),
    cache_lu    NUMERIC(8,4) NOT NULL CHECK (cache_lu >= 0),
    cache_ecrit NUMERIC(8,4) NOT NULL CHECK (cache_ecrit >= 0),
    sortie      NUMERIC(8,4) NOT NULL CHECK (sortie >= 0)
);

INSERT INTO tarif_modele (modele, entree, cache_lu, cache_ecrit, sortie) VALUES
    ('claude-fable-5-1',          10.00, 0.25, 12.50, 50.00),
    ('claude-opus-5-5',            4.00, 0.20,  5.00, 20.00),
    ('claude-sonnet-5-5',          2.00, 0.20,  2.50, 10.00),
    ('claude-sonnet-5',            2.00, 0.20,  2.50, 10.00),
    ('claude-haiku-5-5',           0.10, 0.01,  0.125, 0.50),
    ('claude-haiku-4-5',           1.00, 0.10,  1.25,  5.00),
    ('claude-haiku-4-5-20251001',  1.00, 0.10,  1.25,  5.00)
ON CONFLICT (modele) DO UPDATE
    SET entree = EXCLUDED.entree, cache_lu = EXCLUDED.cache_lu,
        cache_ecrit = EXCLUDED.cache_ecrit, sortie = EXCLUDED.sortie;

-- FOU-9 : qui a répondu. « serveur » : la clé d'API du serveur, comme avant.
ALTER TABLE appel_coach ADD COLUMN IF NOT EXISTS fournisseur VARCHAR(12);
ALTER TABLE appel_coach DROP CONSTRAINT IF EXISTS appel_coach_fournisseur_connu;
ALTER TABLE appel_coach ADD CONSTRAINT appel_coach_fournisseur_connu
    CHECK (fournisseur IS NULL
           OR fournisseur IN ('claude_code', 'api', 'gemini_cli', 'serveur'));

ALTER TABLE echange ADD COLUMN IF NOT EXISTS fournisseur VARCHAR(12);
