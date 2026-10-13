-- =============================================================================
-- 060 : le foyer, ses invitations et les appareils               (FOY, CNX, NOT-16)
--
-- Rejouable.
--
-- Les comptes se réunissent en foyer. Un administrateur l'ouvre, invite par un
-- code valable 48 heures, règle qui peut ajouter, modifier et arrêter les
-- tâches, et peut passer son rôle. Le rôle « admin » du compte reste celui de
-- l'administrateur du serveur (FOY-11) : ce sont deux rôles distincts, tenus
-- aujourd'hui par le même compte.
--
-- Le premier foyer réunit les comptes existants : c'est sql/apres/060, qui
-- appelle amorcer_foyer() une fois la fonction chargée.
-- =============================================================================

CREATE TABLE IF NOT EXISTS foyer (
    id_foyer          SERIAL       PRIMARY KEY,
    nom               VARCHAR(60)  NOT NULL DEFAULT 'Le foyer'
                                   CHECK (length(btrim(nom)) BETWEEN 1 AND 60),
    id_administrateur INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur),
    ajout_taches      VARCHAR(10)  NOT NULL DEFAULT 'tous'
                                   CHECK (ajout_taches IN ('tous', 'admin')),
    modif_taches      VARCHAR(10)  NOT NULL DEFAULT 'tous'
                                   CHECK (modif_taches IN ('tous', 'admin')),
    cree_le           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    ferme_le          TIMESTAMPTZ
);

COMMENT ON TABLE foyer IS
    'FOY-1 : les personnes qui vivent ensemble et partagent tâches, maison et planning.';
COMMENT ON COLUMN foyer.id_administrateur IS
    'FOY-2 : l''administrateur du foyer, un seul. Distinct de l''administrateur du serveur.';
COMMENT ON COLUMN foyer.ajout_taches IS
    'FOY-6 : qui peut ajouter des tâches. « tous » par défaut, ou « admin ».';
COMMENT ON COLUMN foyer.modif_taches IS
    'FOY-6 : qui peut modifier et arrêter les tâches. « tous » par défaut, ou « admin ».';
COMMENT ON COLUMN foyer.ferme_le IS
    'FOY-7 : le dernier membre est parti. Le foyer garde son historique.';

ALTER TABLE utilisateur
    ADD COLUMN IF NOT EXISTS id_foyer INTEGER REFERENCES foyer (id_foyer);

COMMENT ON COLUMN utilisateur.id_foyer IS
    'FOY-1 : le foyer du compte, un au plus. Vide : aucun foyer.';

CREATE INDEX IF NOT EXISTS utilisateur_id_foyer_idx ON utilisateur (id_foyer);


-- -----------------------------------------------------------------------------
-- Les invitations                                                       (FOY-3)
--
-- Le code n'est jamais stocké, seulement son empreinte SHA-256 : il ouvre un
-- compte, comme un mot de passe. Il sert une fois et vaut 48 heures.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS invitation (
    id_invitation  SERIAL       PRIMARY KEY,
    id_foyer       INTEGER      NOT NULL REFERENCES foyer (id_foyer),
    empreinte_code CHAR(64)     NOT NULL UNIQUE,
    cree_par       INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur),
    cree_le        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    expire_le      TIMESTAMPTZ  NOT NULL,
    servie_le      TIMESTAMPTZ,
    servie_par     INTEGER      REFERENCES utilisateur (id_utilisateur),
    annulee_le     TIMESTAMPTZ,
    CHECK (expire_le > cree_le),
    CHECK ((servie_le IS NULL) = (servie_par IS NULL)),
    CHECK (servie_le IS NULL OR annulee_le IS NULL)
);

COMMENT ON TABLE invitation IS
    'FOY-3 : un code pour rejoindre un foyer, valable 48 heures et à usage unique.';
COMMENT ON COLUMN invitation.empreinte_code IS
    'SHA-256 du code, en hexadécimal. Le code lui-même n''est montré qu''une fois, à sa création.';


-- -----------------------------------------------------------------------------
-- Les appareils                                                        (NOT-16)
--
-- Un iPhone où le compte est connecté, et son jeton de notification Apple.
-- Le lot 3 s'en sert pour envoyer ; la déconnexion le retire (CNX-6).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS appareil (
    id_appareil        SERIAL       PRIMARY KEY,
    id_utilisateur     INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur)
                                    ON DELETE CASCADE,
    jeton_notification VARCHAR(200) NOT NULL UNIQUE
                                    CHECK (jeton_notification ~ '^[0-9a-fA-F]{32,200}$'),
    nom                VARCHAR(80),
    environnement      VARCHAR(20)  NOT NULL DEFAULT 'production'
                                    CHECK (environnement IN ('production', 'developpement')),
    enregistre_le      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    vu_le              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE appareil IS
    'NOT-16 : un iPhone du compte, avec son jeton de notification Apple.';
COMMENT ON COLUMN appareil.environnement IS
    'Le serveur d''Apple à joindre : celui de développement pour une appli lancée depuis Xcode.';

CREATE INDEX IF NOT EXISTS appareil_id_utilisateur_idx ON appareil (id_utilisateur);
