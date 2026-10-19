-- =============================================================================
-- 072 : les demandes, et l'accord de l'utilisateur             (ACC-1 à ACC-14)
--
-- Rejouable.
--
-- Un modèle, quel que soit son client, ne change ni le planning, ni les
-- tâches, ni les absences : il dépose une demande. Elle est essayée au dépôt,
-- dans une transaction annulée, et n'est gardée que si la base l'accepterait.
-- L'utilisateur l'accepte ou la refuse dans l'appli ; à l'accord, l'API la
-- fait par la même route que le geste à la main, avec les mêmes droits.
-- =============================================================================

CREATE TABLE IF NOT EXISTS demande (
    id_demande     BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur INTEGER      NOT NULL REFERENCES utilisateur ON DELETE CASCADE,
    -- ACC-2 : une action de la liste fermée (section F.8.2).
    action         VARCHAR(30)  NOT NULL
        CHECK (action IN ('tache', 'modification_tache', 'arret_tache', 'lien', 'report',
                          'faite', 'absence', 'occupation', 'allegement', 'conflit',
                          'seance')),
    parametres     JSONB        NOT NULL DEFAULT '{}'
        CONSTRAINT demande_parametres_objet CHECK (jsonb_typeof(parametres) = 'object'),
    -- ACC-12 : ce qui changerait, en une phrase, écrite par l'API depuis les
    -- paramètres et la base, jamais par le modèle.
    resume         TEXT         NOT NULL CHECK (btrim(resume) <> ''),
    motif          VARCHAR(300) NOT NULL CHECK (btrim(motif) <> ''),
    origine        VARCHAR(8)   NOT NULL CHECK (origine IN ('HAL', 'client')),
    client         VARCHAR(60),
    id_appel       BIGINT       REFERENCES appel_coach ON DELETE SET NULL,
    id_session     UUID         REFERENCES session_mcp ON DELETE SET NULL,
    operation      TEXT         NOT NULL,
    etat           VARCHAR(10)  NOT NULL DEFAULT 'en_attente'
        CHECK (etat IN ('en_attente', 'acceptee', 'refusee', 'expiree', 'echouee')),
    deposee_le     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    expire_le      TIMESTAMPTZ  NOT NULL,
    decidee_le     TIMESTAMPTZ,
    motif_echec    TEXT,
    CONSTRAINT demande_origine_coherente
        CHECK ((origine = 'client') = (client IS NOT NULL)),
    CONSTRAINT demande_decision_datee
        CHECK ((etat = 'en_attente') = (decidee_le IS NULL)),
    CONSTRAINT demande_echec_motive
        CHECK ((etat = 'echouee') = (motif_echec IS NOT NULL)),
    -- ACC-8 : 48 heures au plus.
    CONSTRAINT demande_duree
        CHECK (expire_le > deposee_le AND expire_le <= deposee_le + INTERVAL '48 hours')
);
CREATE INDEX IF NOT EXISTS demande_en_attente
    ON demande (id_utilisateur, deposee_le) WHERE etat = 'en_attente';

-- ACC-9 : une demande d'un client part en notification, avec ses deux boutons.
ALTER TABLE notification
    ADD COLUMN IF NOT EXISTS id_demande BIGINT REFERENCES demande ON DELETE SET NULL;
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_type_check;
ALTER TABLE notification ADD CONSTRAINT notification_type_check
    CHECK (type IN ('rappel', 'bilan', 'alerte', 'sport', 'coach', 'changement',
                    'administration', 'demande'));
