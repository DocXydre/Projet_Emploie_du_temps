-- =============================================================================
-- 088 : les participants d'une occurrence à plusieurs          (RGL-7, lot B1)
--
-- Rejouable. La table et l'index se créent s'ils manquent.
-- =============================================================================

CREATE TABLE IF NOT EXISTS occurrence_participant (
    id_occurrence  INTEGER NOT NULL REFERENCES occurrence (id_occurrence) ON DELETE CASCADE,
    id_utilisateur INTEGER NOT NULL REFERENCES utilisateur (id_utilisateur) ON DELETE CASCADE,
    PRIMARY KEY (id_occurrence, id_utilisateur)
);

CREATE INDEX IF NOT EXISTS occurrence_participant_par_utilisateur ON occurrence_participant (id_utilisateur);

COMMENT ON TABLE occurrence_participant IS 'RGL-7 : les membres qui font ensemble une occurrence d''une tâche à plusieurs (règle a_plusieurs). occurrence.id_utilisateur garde le premier participant.';
