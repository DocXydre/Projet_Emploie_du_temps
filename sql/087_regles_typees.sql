-- =============================================================================
-- 087 : les règles typées, première sorte « a_plusieurs »     (RGL-1 à RGL-3, RGL-10, lot A)
--
-- Rejouable. Les tables se créent si elles manquent, la sorte se réécrit, les contraintes se refont.
-- =============================================================================

CREATE TABLE IF NOT EXISTS sorte_regle (
    code VARCHAR(24) PRIMARY KEY,
    cible VARCHAR(6) NOT NULL,
    libelle VARCHAR(80) NOT NULL,
    description TEXT NOT NULL,
    parametres JSONB NOT NULL DEFAULT '{}',
    pose_occurrence BOOLEAN NOT NULL DEFAULT FALSE
);

ALTER TABLE sorte_regle DROP CONSTRAINT IF EXISTS sorte_regle_cible_connue;
ALTER TABLE sorte_regle ADD CONSTRAINT sorte_regle_cible_connue CHECK (cible IN ('source', 'tache'));

CREATE TABLE IF NOT EXISTS regle (
    id_regle BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_tache INTEGER REFERENCES tache (id_tache) ON DELETE CASCADE,
    id_source INTEGER REFERENCES source (id_source) ON DELETE CASCADE,
    sorte VARCHAR(24) REFERENCES sorte_regle (code),
    parametres JSONB NOT NULL DEFAULT '{}',
    condition_sql TEXT,
    fonction VARCHAR(63) UNIQUE,
    phrase VARCHAR(500) NOT NULL,
    dite_par INTEGER REFERENCES utilisateur (id_utilisateur),
    id_appel BIGINT REFERENCES appel_coach (id_appel) ON DELETE SET NULL,
    etat VARCHAR(10) NOT NULL DEFAULT 'active',
    motif_echec TEXT,
    creee_le TIMESTAMPTZ NOT NULL DEFAULT now(),
    retiree_le TIMESTAMPTZ,
    remplacee_par BIGINT REFERENCES regle (id_regle) ON DELETE SET NULL
);

ALTER TABLE regle DROP CONSTRAINT IF EXISTS regle_une_cible;
ALTER TABLE regle ADD CONSTRAINT regle_une_cible CHECK ((id_tache IS NULL) <> (id_source IS NULL));

ALTER TABLE regle DROP CONSTRAINT IF EXISTS regle_sorte_ou_condition;
ALTER TABLE regle ADD CONSTRAINT regle_sorte_ou_condition CHECK ((sorte IS NULL) <> (condition_sql IS NULL));

ALTER TABLE regle DROP CONSTRAINT IF EXISTS regle_fonction_avec_condition;
ALTER TABLE regle ADD CONSTRAINT regle_fonction_avec_condition CHECK ((condition_sql IS NULL) = (fonction IS NULL));

ALTER TABLE regle DROP CONSTRAINT IF EXISTS regle_etat_connu;
ALTER TABLE regle ADD CONSTRAINT regle_etat_connu CHECK (etat IN ('active', 'en_echec', 'retiree'));

ALTER TABLE regle DROP CONSTRAINT IF EXISTS regle_echec_motif;
ALTER TABLE regle ADD CONSTRAINT regle_echec_motif CHECK ((etat = 'en_echec') = (motif_echec IS NOT NULL));

ALTER TABLE regle DROP CONSTRAINT IF EXISTS regle_retiree_date;
ALTER TABLE regle ADD CONSTRAINT regle_retiree_date CHECK ((etat = 'retiree') = (retiree_le IS NOT NULL));

CREATE INDEX IF NOT EXISTS regle_par_tache ON regle (id_tache) WHERE id_tache IS NOT NULL;
CREATE INDEX IF NOT EXISTS regle_par_source ON regle (id_source) WHERE id_source IS NOT NULL;

COMMENT ON TABLE sorte_regle IS 'RGL-2 : le catalogue des règles typées, une donnée remplie par migration. HAL lit la description de chaque sorte et de ses paramètres.';
COMMENT ON TABLE regle IS 'RGL-1 : une règle dictée à HAL, sur une tâche ou une source. Une règle changée garde sa version d''avant (retiree_le, remplacee_par : RGL-10).';

INSERT INTO sorte_regle (code, cible, libelle, description, parametres, pose_occurrence)
VALUES (
    'a_plusieurs', 
    'tache', 
    'Se fait à plusieurs', 
    'Combien de membres du foyer sont présents ensemble pour faire la tâche. Paramètre « membres » : un entier, 2 pour l''instant (le choix des participants n''existe pas encore). Exemple : « le grand nettoyage se fait à deux ».',
    '{"membres": {"type": "integer", "minimum": 2, "maximum": 2, "description": "nombre de membres présents ensemble ; 2 seulement pour l''instant"}}'::jsonb, 
    FALSE
) ON CONFLICT (code) DO UPDATE SET 
    cible = EXCLUDED.cible, 
    libelle = EXCLUDED.libelle, 
    description = EXCLUDED.description, 
    parametres = EXCLUDED.parametres, 
    pose_occurrence = EXCLUDED.pose_occurrence;
