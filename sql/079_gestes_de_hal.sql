-- =============================================================================
-- 079 : les gestes demandés à HAL                              (ACT-1, ACT-2, lot 17)
--
-- Rejouable.
--
-- Dans l'appli, ce que l'utilisateur demande à HAL se fait sans bouton
-- d'accord. Le geste passe par une demande, essayée comme les autres (ACC-3),
-- que le serveur accepte seul à `auto_le`, quelques secondes après la réponse,
-- sauf si « Annuler » l'a refusée entre-temps. Une demande d'un client externe
-- garde son accord (ACT-6).
-- =============================================================================

ALTER TABLE demande
    ADD COLUMN IF NOT EXISTS geste   BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS auto_le TIMESTAMPTZ;

-- ACT-6 : seul HAL, dans l'appli, fait des gestes.
ALTER TABLE demande DROP CONSTRAINT IF EXISTS demande_geste;
ALTER TABLE demande ADD CONSTRAINT demande_geste
    CHECK (NOT geste OR origine = 'HAL');
ALTER TABLE demande DROP CONSTRAINT IF EXISTS demande_auto_le;
ALTER TABLE demande ADD CONSTRAINT demande_auto_le
    CHECK (auto_le IS NULL OR geste);

CREATE INDEX IF NOT EXISTS demande_gestes_dus ON demande (auto_le)
    WHERE geste AND etat = 'en_attente';

COMMENT ON COLUMN demande.geste IS
    'ACT-2 : demandée à HAL dans l''appli. Elle s''accepte seule à auto_le, sauf annulation.';
COMMENT ON COLUMN demande.auto_le IS
    'ACT-2 : quand le serveur l''accepte de lui-même, posé une fois la réponse de HAL rendue.';

-- ACT-1 : les gestes de l'onglet Sport rejoignent la liste fermée des actions.
ALTER TABLE demande DROP CONSTRAINT IF EXISTS demande_action_check;
ALTER TABLE demande ADD CONSTRAINT demande_action_check
    CHECK (action IN ('tache', 'modification_tache', 'arret_tache', 'lien', 'report',
                      'faite', 'absence', 'occupation', 'allegement', 'conflit',
                      'seance', 'valider_semaine', 'valider_seance', 'pas_faite'));
