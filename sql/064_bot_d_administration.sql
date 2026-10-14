-- =============================================================================
-- 064 : le bot d'administration                              (ADM-1 à ADM-5)
--
-- Rejouable.
--
-- Le bot ne parle plus qu'à l'administrateur du serveur. Les membres du foyer
-- ont tout dans l'appli : leurs comptes Telegram sont déliés, et le bot ne
-- transporte plus que les alertes de l'administration.
-- =============================================================================

-- ADM-2 : une alerte de l'administration est une notification à part. Elle
-- ne part que par le bot, jamais par Apple.
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_type_check;
ALTER TABLE notification ADD CONSTRAINT notification_type_check
    CHECK (type IN ('rappel', 'bilan', 'alerte', 'sport', 'coach', 'changement',
                    'administration'));


-- -----------------------------------------------------------------------------
-- Les alertes en cours                                                 (ADM-4)
--
-- Une ligne par problème, désigné par une clé stable : « source:ADE »,
-- « apple », « api », « disque ». Elle dit quand l'alerte a été annoncée pour
-- la dernière fois, pour ne pas la répéter plus d'une fois par heure, et
-- quand le problème a été réglé.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alerte_admin (
    cle              VARCHAR(60) PRIMARY KEY,
    texte            TEXT        NOT NULL,
    ouverte_le       TIMESTAMPTZ NOT NULL DEFAULT now(),
    annoncee_le      TIMESTAMPTZ NOT NULL DEFAULT now(),
    reglee_le        TIMESTAMPTZ
);

COMMENT ON TABLE alerte_admin IS
    'ADM-4 : un problème signalé à l''administrateur. Ouvert tant que reglee_le
     est vide ; annoncé au plus une fois par heure.';


-- ADM-5 : seul l'administrateur du serveur garde son compte Telegram.
-- Les notifications des membres restent en base telles quelles : le bot ne
-- les lit plus (ADM-5), l'appli garde sa colonne à elle (apple_statut).
UPDATE utilisateur SET id_telegram = NULL
 WHERE id_telegram IS NOT NULL AND role <> 'admin';
