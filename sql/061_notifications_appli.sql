-- =============================================================================
-- 061 : les notifications de l'appli                       (NOT-14 à NOT-19)
--
-- Rejouable.
--
-- Chacun règle ses heures : bilan, relance, récap de HAL et silence de la
-- nuit. L'ordonnanceur passe toutes les cinq minutes et sert à chacun ce qui
-- est dû à son heure, une fois par jour. Les notifications partent aussi par
-- le service d'Apple, vers les iPhone où le compte est connecté.
--
-- Le bot continue d'envoyer ce qu'il envoyait : il ne s'arrête qu'à la bascule
-- complète vers l'appli.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Les heures de chacun                                                 (NOT-15)
-- -----------------------------------------------------------------------------
ALTER TABLE utilisateur
    ADD COLUMN IF NOT EXISTS heure_bilan   TIME NOT NULL DEFAULT '07:00',
    ADD COLUMN IF NOT EXISTS heure_relance TIME NOT NULL DEFAULT '21:00',
    ADD COLUMN IF NOT EXISTS heure_recap   TIME NOT NULL DEFAULT '23:00',
    ADD COLUMN IF NOT EXISTS silence_debut TIME NOT NULL DEFAULT '23:30',
    ADD COLUMN IF NOT EXISTS silence_fin   TIME NOT NULL DEFAULT '07:30';

ALTER TABLE utilisateur DROP CONSTRAINT IF EXISTS utilisateur_silence_non_vide;
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_silence_non_vide
    CHECK (silence_debut <> silence_fin);

COMMENT ON COLUMN utilisateur.heure_bilan IS
    'NOT-1, NOT-15 : l''heure du bilan du matin de ce compte.';
COMMENT ON COLUMN utilisateur.heure_relance IS
    'NOT-15 : l''heure de la relance du soir, « c''est fait ? ».';
COMMENT ON COLUMN utilisateur.heure_recap IS
    'NOT-15, PLN-9 : l''heure du récap de HAL, et de la clôture des séances du jour.';
COMMENT ON COLUMN utilisateur.silence_debut IS
    'NOT-14 : rien ne part entre silence_debut et silence_fin, plage qui peut passer minuit.';

-- Ce qui a déjà été servi aujourd'hui : un passage de l'ordonnanceur ne sert
-- jamais deux fois le même rendez-vous, même après un redémarrage.
CREATE TABLE IF NOT EXISTS passage (
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur (id_utilisateur)
                               ON DELETE CASCADE,
    moment         VARCHAR(10) NOT NULL CHECK (moment IN ('bilan', 'relance', 'recap')),
    jour           DATE        NOT NULL,
    servi_le       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id_utilisateur, moment, jour)
);

COMMENT ON TABLE passage IS
    'NOT-15 : le bilan, la relance ou le récap d''un compte, déjà servi pour ce jour.';


-- -----------------------------------------------------------------------------
-- L'envoi par Apple                                                    (NOT-16)
--
-- Le bot garde la colonne `statut`. L'envoi par Apple a la sienne : les deux
-- voies vivent côte à côte jusqu'à la bascule. Les notifications d'avant cette
-- migration sont marquées « ancienne » : un iPhone qui s'enregistre ne reçoit
-- pas tout l'historique d'un coup.
-- -----------------------------------------------------------------------------
ALTER TABLE notification
    ADD COLUMN IF NOT EXISTS apple_statut VARCHAR(14) NOT NULL DEFAULT 'ancienne',
    ADD COLUMN IF NOT EXISTS apple_essais SMALLINT    NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS apple_envoyee_le TIMESTAMPTZ;
ALTER TABLE notification ALTER COLUMN apple_statut SET DEFAULT 'a_envoyer';

ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_apple_statut_check;
ALTER TABLE notification ADD CONSTRAINT notification_apple_statut_check
    CHECK (apple_statut IN ('a_envoyer', 'envoyee', 'sans_appareil', 'echec',
                            'perimee', 'ancienne'));

CREATE INDEX IF NOT EXISTS notification_apple_a_envoyer_idx
    ON notification (date_creation) WHERE apple_statut = 'a_envoyer';

COMMENT ON COLUMN notification.apple_statut IS
    'NOT-16 : l''envoi par Apple. « sans_appareil » : aucun iPhone enregistré à la création.';

-- NOT-17 : un changement du planning, avec sa raison.
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_type_check;
ALTER TABLE notification ADD CONSTRAINT notification_type_check
    CHECK (type IN ('rappel', 'bilan', 'alerte', 'sport', 'coach', 'changement'));

ALTER TABLE notification ADD COLUMN IF NOT EXISTS operation TEXT;
COMMENT ON COLUMN notification.operation IS
    'NOT-17 : l''action du journal que la notification raconte. L''appli ouvre l''Historique dessus.';


-- -----------------------------------------------------------------------------
-- Les changements à annoncer                                          (NOT-17)
--
-- Jusqu'où le journal a été lu. Posé à la fin du journal actuel : ce qui s'est
-- passé avant cette migration ne s'annonce pas.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS curseur (
    nom     VARCHAR(30) PRIMARY KEY,
    dernier BIGINT      NOT NULL
);

INSERT INTO curseur (nom, dernier)
SELECT 'changements', COALESCE(max(id_evenement), 0) FROM evenement
ON CONFLICT (nom) DO NOTHING;

COMMENT ON TABLE curseur IS
    'Le dernier événement du journal déjà traité, par lecteur.';


-- -----------------------------------------------------------------------------
-- Le « ! » de l'orbe                                                  (NOT-18)
-- -----------------------------------------------------------------------------
ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS orbe_vu_le TIMESTAMPTZ;

COMMENT ON COLUMN utilisateur.orbe_vu_le IS
    'NOT-18 : la dernière ouverture du panneau de HAL. Ce que HAL dit après met un « ! » sur l''orbe.';
