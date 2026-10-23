-- =============================================================================
-- 083 : les erreurs récentes, communes à l'API et au travailleur      (ADM-3)
--
-- Rejouable.
--
-- L'API et le travailleur (l'ordonnanceur, le bot et les appels planifiés de
-- HAL) tournent maintenant dans deux processus. Les erreurs étaient gardées en
-- mémoire, dans le processus où elles arrivaient : le bot, passé dans le
-- travailleur, n'aurait plus vu celles de l'API. Elles sont donc écrites ici,
-- et ne restent qu'une journée : /erreurs dit ce qui casse maintenant, pas
-- l'histoire du serveur.
-- =============================================================================

CREATE TABLE IF NOT EXISTS erreur_recente (
    id_erreur  SERIAL       PRIMARY KEY,
    quand      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    processus  VARCHAR(20)  NOT NULL CHECK (processus IN ('api', 'travailleur')),
    module     VARCHAR(120) NOT NULL,
    message    TEXT         NOT NULL
);

COMMENT ON TABLE erreur_recente IS
    'ADM-3 : les erreurs écrites au journal par l''API ou le travailleur, gardées une journée.';
COMMENT ON COLUMN erreur_recente.processus IS
    'Le processus où l''erreur est arrivée : « api » ou « travailleur ».';

CREATE INDEX IF NOT EXISTS erreur_recente_quand_idx ON erreur_recente (quand);
