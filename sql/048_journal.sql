-- =============================================================================
-- 048 : le journal des événements                                (JRN-1 à JRN-9)
--
-- Rejouable.
--
-- Presque toutes les questions posées à cette application ont la même forme :
-- « pourquoi ça a fait ça ? ». Pourquoi le lundi est resté en week-end, pourquoi
-- cette tâche a changé de jour, pourquoi /billets n'a rien dit. Jusqu'ici, y
-- répondre demandait de relire le code et de deviner.
--
-- Cette table note ce qui change, qui l'a déclenché, et dans quelle action. Une
-- action, c'est une commande du bot, un appel de l'API ou un passage de
-- l'ordonnanceur : tout ce qu'elle modifie porte le même numéro d'opération.
-- La cause se lit donc à côté de l'effet. « Thomas a déclaré une absence » et
-- « l'aspirateur passe à Lorette » sont deux lignes de la même opération.
--
-- Cette migration ne crée que la table. Les fonctions et les déclencheurs qui
-- la remplissent sont dans sql/definitions/, comme tout le reste depuis 047.
-- =============================================================================

CREATE TABLE IF NOT EXISTS evenement (
    id_evenement BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quand        TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    -- Ce qui relie les lignes d'une même action. Sans contexte (une requête
    -- tapée à la main dans psql), c'est le numéro de la transaction.
    operation    TEXT        NOT NULL,
    -- Un pseudo, ou « ordonnanceur », « bot », « deploiement », « direct ».
    acteur       TEXT        NOT NULL,
    -- « bot : absent », « api : POST /absences », « Bilan du matin ».
    origine      TEXT,

    -- La table touchée, ou le nom d'un fait qui n'a pas de table :
    -- « deploiement », « releve », « demarrage ».
    objet        TEXT        NOT NULL,
    id_objet     BIGINT,
    -- De quoi il s'agit, en clair, pour rester lisible après la suppression de
    -- la ligne d'origine : « Sortir les poubelles », « Lusse ».
    libelle      TEXT,

    -- L'état des colonnes suivies, avant et après l'opération. NULL avant :
    -- la ligne a été créée. NULL après : elle a été supprimée.
    avant        JSONB,
    apres        JSONB,
    detail       TEXT,

    -- JRN-6 : la vie du foyer se lit à deux. Le technique, sources en panne et
    -- déploiements, est réservé à l'administrateur.
    technique    BOOLEAN     NOT NULL DEFAULT FALSE
);

-- Retrouver la ligne d'un objet dans l'opération en cours, à chaque changement.
CREATE INDEX IF NOT EXISTS evenement_par_operation
    ON evenement (operation, objet, id_objet);

-- Lire les plus récents, et purger les plus anciens.
CREATE INDEX IF NOT EXISTS evenement_par_date ON evenement (quand DESC);

COMMENT ON TABLE evenement IS
    'JRN : ce qui a changé, qui l''a déclenché, et dans quelle action. Une ligne
     par objet et par opération, quel que soit le nombre de retouches. Purgé
     après 90 jours.';
