-- =============================================================================
-- 001 : schéma
--
-- Les commentaires renvoient aux règles de gestion du cahier des charges (R1…R42)
-- et aux contraintes d'intégrité de la section 7.
--
-- Conventions :
--   - tous les horodatages sont des TIMESTAMPTZ, donc stockés en UTC ;
--   - les plages horaires sont des TSTZRANGE, pas deux colonnes début et fin ;
--   - les énumérations sont des VARCHAR contraints par CHECK : lisibles en SQL
--     et modifiables par migration, sans type ENUM à faire évoluer.
-- =============================================================================

-- Nécessaire pour mêler l'égalité sur un entier et le chevauchement sur un
-- intervalle dans une même contrainte d'exclusion.
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- -----------------------------------------------------------------------------
-- Utilisateur                                                             (R1)
-- -----------------------------------------------------------------------------
CREATE TABLE utilisateur (
    id_utilisateur  SERIAL       PRIMARY KEY,
    pseudo          VARCHAR(50)  NOT NULL UNIQUE,
    nom             VARCHAR(50)  NOT NULL,
    role            VARCHAR(20)  NOT NULL DEFAULT 'standard'
                                 CHECK (role IN ('admin', 'standard')),
    fuseau          VARCHAR(50)  NOT NULL DEFAULT 'Europe/Paris',
    cle_api         VARCHAR(64)  NOT NULL UNIQUE
                                 CHECK (length(cle_api) >= 32),
    jeton_calendrier VARCHAR(64) NOT NULL UNIQUE
                                 DEFAULT replace(gen_random_uuid()::TEXT, '-', ''),
    id_telegram     BIGINT       UNIQUE,
    actif           BOOLEAN      NOT NULL DEFAULT TRUE,
    date_creation   DATE         NOT NULL DEFAULT CURRENT_DATE
);

COMMENT ON COLUMN utilisateur.cle_api IS
    'Authentification de l''API. Générée hors base, jamais versionnée (R1).';

COMMENT ON COLUMN utilisateur.jeton_calendrier IS
    'Abonnement iCalendar seul. Distinct de la clé d''API car il voyage dans '
    'une URL que le téléphone conserve en clair : s''il fuite, il ne donne que '
    'la lecture du planning, et se renouvelle sans rien casser d''autre (R61).';


-- -----------------------------------------------------------------------------
-- Source de contraintes                                                   (R4)
-- -----------------------------------------------------------------------------
CREATE TABLE source (
    id_source          SERIAL       PRIMARY KEY,
    code               VARCHAR(30)  NOT NULL UNIQUE,
    libelle            VARCHAR(100) NOT NULL,
    mode_collecte      VARCHAR(20)  NOT NULL
                                    CHECK (mode_collecte IN ('ics', 'scraping', 'manuelle')),
    url                TEXT,
    frequence_heures   INTEGER      NOT NULL DEFAULT 24
                                    CHECK (frequence_heures > 0),
    derniere_collecte  TIMESTAMPTZ,
    etat               VARCHAR(20)  NOT NULL DEFAULT 'ok'
                                    CHECK (etat IN ('ok', 'en_panne')),
    configuration      JSONB        NOT NULL DEFAULT '{}'::JSONB,
    id_utilisateur     INTEGER      REFERENCES utilisateur (id_utilisateur),
    active             BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON COLUMN source.id_utilisateur IS
    'À qui appartient cet emploi du temps. Sans cette colonne, l''ordonnanceur
     ne saurait pas à qui rattacher les occupations qu''il collecte la nuit.';

COMMENT ON COLUMN source.configuration IS
    'Réglages du collecteur : groupe de TD, langues suivies, horizon. En base
     plutôt que dans le code, pour qu''un changement de groupe au second
     semestre ne demande pas de redéploiement.';

COMMENT ON COLUMN source.derniere_collecte IS
    'Dernière collecte réussie. Au-delà de deux fois la fréquence, la source est
     déclarée en panne par la vue v_source_sante (R30).';


-- -----------------------------------------------------------------------------
-- Occupation : contrainte dure et non déplaçable                     (R2, R3, R5)
-- -----------------------------------------------------------------------------
CREATE TABLE occupation (
    id_occupation   SERIAL       PRIMARY KEY,
    id_utilisateur  INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur),
    id_source       INTEGER      NOT NULL REFERENCES source (id_source),
    type            VARCHAR(20)  NOT NULL
                                 CHECK (type IN ('cours', 'travail', 'sommeil', 'autre')),
    libelle         VARCHAR(150) NOT NULL,
    periode         TSTZRANGE    NOT NULL,
    lieu            VARCHAR(100),
    details         TEXT,
    cle_externe     VARCHAR(200),
    date_collecte   TIMESTAMPTZ  NOT NULL DEFAULT now(),

    -- Une occupation a un début et une fin connus, et dure au moins un instant.
    CONSTRAINT occupation_periode_bornee CHECK (
        NOT isempty(periode)
        AND lower(periode) IS NOT NULL
        AND upper(periode) IS NOT NULL
    ),

    -- R5 : la clé externe permet de retrouver l'occupation à la collecte
    -- suivante et de la mettre à jour au lieu de la dupliquer. Plusieurs NULL
    -- ne se gênent pas entre eux, la saisie manuelle n'est donc pas contrainte.
    CONSTRAINT occupation_cle_externe_unique UNIQUE (id_source, cle_externe),

    -- R3 : on ne peut pas être en cours et en shift au même moment. Le sommeil
    -- et les occupations personnelles sont exclus de la règle : ils peuvent
    -- légitimement recouvrir un shift de nuit.
    CONSTRAINT occupation_sans_chevauchement
        EXCLUDE USING gist (id_utilisateur WITH =, periode WITH &&)
        WHERE (type IN ('cours', 'travail'))
);

CREATE INDEX occupation_periode_idx ON occupation USING gist (periode);

COMMENT ON COLUMN occupation.details IS
    'Enseignant et salle, tels que publiés par la source. Exportés en
     DESCRIPTION dans le flux iCalendar : c''est ce qu''on veut lire sur son
     téléphone en arrivant à la fac.';


-- -----------------------------------------------------------------------------
-- Absence : les jours où l'on n'est pas dans l'appartement       (R57 à R60)
--
-- Une absence n'est pas une occupation. Être en cours empêche de faire le
-- ménage à ce moment-là ; être à Saint-Dié empêche de le faire du tout, et
-- surtout dispense de le faire : on ne salit pas un appartement où l'on n'est
-- pas.
-- -----------------------------------------------------------------------------
CREATE TABLE absence (
    id_absence      SERIAL       PRIMARY KEY,
    id_utilisateur  INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur),
    periode         TSTZRANGE    NOT NULL,
    lieu            VARCHAR(100),
    origine         VARCHAR(20)  NOT NULL DEFAULT 'manuelle'
                                 CHECK (origine IN ('manuelle', 'trajet')),
    commentaire     TEXT,
    date_creation   TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT absence_periode_bornee CHECK (
        NOT isempty(periode)
        AND lower(periode) IS NOT NULL
        AND upper(periode) IS NOT NULL
    ),

    -- On ne peut pas être absent deux fois en même temps.
    CONSTRAINT absence_sans_chevauchement
        EXCLUDE USING gist (id_utilisateur WITH =, periode WITH &&)
);

CREATE INDEX absence_periode_idx ON absence USING gist (periode);

COMMENT ON COLUMN absence.origine IS
    'manuelle : déclarée au bot, par exemple un départ en voiture.
     trajet : déduite d''un billet de train confirmé.';


-- -----------------------------------------------------------------------------
-- Conflit horaire                                                  (R45, R46)
--
-- Une source publie parfois deux occupations au même moment. La contrainte
-- d'exclusion en refuse une : plutôt que de la perdre, on la garde ici en
-- attente d'arbitrage.
--
-- La règle des deux semaines évite de déranger pour rien : un conflit dans un
-- mois se résoudra probablement tout seul quand l'emploi du temps sera corrigé.
-- -----------------------------------------------------------------------------
CREATE TABLE conflit (
    id_conflit       SERIAL       PRIMARY KEY,
    id_occupation    INTEGER      NOT NULL REFERENCES occupation (id_occupation)
                                  ON DELETE CASCADE,
    id_source        INTEGER      NOT NULL REFERENCES source (id_source),
    cle_externe      VARCHAR(200) NOT NULL,
    libelle          VARCHAR(150) NOT NULL,
    periode          TSTZRANGE    NOT NULL,
    lieu             VARCHAR(100),
    details          TEXT,
    statut           VARCHAR(20)  NOT NULL DEFAULT 'en_attente'
                                  CHECK (statut IN ('en_attente', 'resolu')),
    choix            VARCHAR(20)  CHECK (choix IN ('existante', 'nouvelle')),
    date_detection   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    date_resolution  TIMESTAMPTZ,

    CONSTRAINT conflit_unique UNIQUE (id_source, cle_externe, id_occupation),

    CONSTRAINT conflit_resolution_coherente CHECK (
        statut <> 'resolu' OR (choix IS NOT NULL AND date_resolution IS NOT NULL)
    )
);

CREATE INDEX conflit_en_attente_idx ON conflit (statut) WHERE statut = 'en_attente';

COMMENT ON COLUMN conflit.choix IS
    'existante : on garde ce qui est déjà au planning et la nouvelle version est
     écartée durablement. nouvelle : on remplace. Le choix est mémorisé pour que
     la collecte suivante ne repose pas la même question.';


-- -----------------------------------------------------------------------------
-- Tâche récurrente                                             (R6, R7, R8)
-- -----------------------------------------------------------------------------
CREATE TABLE tache (
    id_tache               SERIAL       PRIMARY KEY,
    code                   VARCHAR(30)  NOT NULL UNIQUE,
    libelle                VARCHAR(100) NOT NULL,
    categorie              VARCHAR(20)  NOT NULL
                                        CHECK (categorie IN ('menage', 'linge', 'vaisselle',
                                                             'animal', 'admin')),
    priorite               SMALLINT     NOT NULL DEFAULT 3
                                        CHECK (priorite BETWEEN 1 AND 5),
    duree_minutes          INTEGER      NOT NULL CHECK (duree_minutes > 0),
    periodicite_min_jours  INTEGER      NOT NULL CHECK (periodicite_min_jours > 0),
    periodicite_max_jours  INTEGER      NOT NULL CHECK (periodicite_max_jours > 0),
    rappel_journee         BOOLEAN      NOT NULL DEFAULT TRUE,
    heure_min              TIME,
    heure_max              TIME,
    utilise_machine        BOOLEAN      NOT NULL DEFAULT FALSE,
    lave_uniforme          BOOLEAN      NOT NULL DEFAULT FALSE,
    requiert_les_deux      BOOLEAN      NOT NULL DEFAULT FALSE,
    reportable             BOOLEAN      NOT NULL DEFAULT TRUE,
    recurrente             BOOLEAN      NOT NULL DEFAULT TRUE,
    id_utilisateur_defaut  INTEGER      REFERENCES utilisateur (id_utilisateur),
    active                 BOOLEAN      NOT NULL DEFAULT TRUE,

    CONSTRAINT tache_periodicite_coherente
        CHECK (periodicite_max_jours >= periodicite_min_jours),

    -- R7 : une tâche est soit un rappel dans la journée, sans heure, soit une
    -- tâche à heure imposée, et elle déclare alors ses deux bornes.
    CONSTRAINT tache_nature_coherente CHECK (
        (rappel_journee AND heure_min IS NULL AND heure_max IS NULL)
        OR (NOT rappel_journee AND heure_min IS NOT NULL
            AND heure_max IS NOT NULL AND heure_max > heure_min)
    ),

    -- Laver l'uniforme suppose de faire tourner la machine.
    CONSTRAINT tache_lavage_coherent CHECK (NOT lave_uniforme OR utilise_machine),

    -- R43 : chercher un moment où deux personnes sont libres en même temps n'a
    -- de sens que sur des heures précises. Un rappel « dans la journée » ne dit
    -- rien de la simultanéité.
    CONSTRAINT tache_duo_coherent CHECK (NOT requiert_les_deux OR NOT rappel_journee)
);

COMMENT ON COLUMN tache.priorite IS
    'De 1 à 5, la plus basse gagne. 1 est réservée à ce qui ne se repousse pas :
     litière du chat, lessive de travail quand le stock est menacé.';

COMMENT ON COLUMN tache.rappel_journee IS
    'Vrai : à faire ce jour-là, sans heure. Sortira en événement journée entière
     dans le flux iCalendar. Faux : créneau horaire précis (R7, R29).';

COMMENT ON COLUMN tache.reportable IS
    'Faux pour la lessive de travail : la repousser reviendrait à se retrouver
     sans uniforme propre (opération 6).';

COMMENT ON COLUMN tache.recurrente IS
    'Faux pour ce qui n''a de sens qu''à la suite d''autre chose : étendre le
     linge ne revient pas tous les jours, seulement après une lessive. Ces
     tâches ne sont créées que par enchaînement (R55).';

COMMENT ON COLUMN tache.requiert_les_deux IS
    'Vrai pour le grand nettoyage : il faut un moment où Thomas et Lorette sont
     libres en même temps. Le placement cherche alors une intersection de
     disponibilités, et notifie s''il n''en existe aucune plutôt que de placer
     la tâche au hasard (R43, R44).';


-- -----------------------------------------------------------------------------
-- Enchaînement entre tâches                                              (R12)
-- -----------------------------------------------------------------------------
CREATE TABLE enchainement (
    id_enchainement    SERIAL  PRIMARY KEY,
    id_tache_source    INTEGER NOT NULL REFERENCES tache (id_tache) ON DELETE CASCADE,
    id_tache_suivante  INTEGER NOT NULL REFERENCES tache (id_tache) ON DELETE CASCADE,
    delai_min_heures   INTEGER NOT NULL DEFAULT 0  CHECK (delai_min_heures >= 0),
    delai_max_heures   INTEGER NOT NULL DEFAULT 24 CHECK (delai_max_heures > 0),

    CONSTRAINT enchainement_unique UNIQUE (id_tache_source, id_tache_suivante),
    CONSTRAINT enchainement_non_reflexif CHECK (id_tache_source <> id_tache_suivante),
    CONSTRAINT enchainement_delais_coherents CHECK (delai_max_heures > delai_min_heures)
);

COMMENT ON TABLE enchainement IS
    'La poussière déclenche l''aspirateur dans les 24 heures, et jamais avant elle (R12, R23).';


-- -----------------------------------------------------------------------------
-- Remplacement : faire ceci vaut avoir fait cela                        (R51)
--
-- Vider entièrement la litière rend le ramassage des crottes sans objet. Sans
-- cette notion, les deux tâches tomberaient le même jour et le système
-- demanderait de faire deux fois le même geste.
-- -----------------------------------------------------------------------------
CREATE TABLE remplacement (
    id_remplacement    SERIAL  PRIMARY KEY,
    id_tache_faite     INTEGER NOT NULL REFERENCES tache (id_tache) ON DELETE CASCADE,
    id_tache_couverte  INTEGER NOT NULL REFERENCES tache (id_tache) ON DELETE CASCADE,

    CONSTRAINT remplacement_unique UNIQUE (id_tache_faite, id_tache_couverte),
    CONSTRAINT remplacement_non_reflexif CHECK (id_tache_faite <> id_tache_couverte)
);

COMMENT ON TABLE remplacement IS
    'Valider la tâche source solde aussi la tâche couverte, à la même date. La
     récurrence de cette dernière repart donc du bon moment (R51).';

COMMENT ON COLUMN enchainement.delai_min_heures IS
    'Délai avant lequel la tâche suivante n''a pas de sens. Zéro pour
     l''aspirateur, qui suit la poussière tout de suite ; douze heures pour le
     pliage, qui attend que le linge ait séché une nuit.';


-- -----------------------------------------------------------------------------
-- Occurrence : une exécution concrète                    (R9, R10, R11, R26)
-- -----------------------------------------------------------------------------
CREATE TABLE occurrence (
    id_occurrence         SERIAL       PRIMARY KEY,
    id_tache              INTEGER      NOT NULL REFERENCES tache (id_tache),
    id_utilisateur        INTEGER      REFERENCES utilisateur (id_utilisateur),
    fenetre               TSTZRANGE    NOT NULL,
    creneau               TSTZRANGE,
    statut                VARCHAR(20)  NOT NULL DEFAULT 'a_placer'
                                       CHECK (statut IN ('a_placer', 'planifiee', 'notifiee',
                                                         'faite', 'reportee', 'abandonnee')),
    origine               VARCHAR(20)  NOT NULL DEFAULT 'recurrence'
                                       CHECK (origine IN ('recurrence', 'manuelle',
                                                          'enchainement', 'stock')),
    epinglee              BOOLEAN      NOT NULL DEFAULT FALSE,
    rappel_journee        BOOLEAN      NOT NULL DEFAULT TRUE,
    utilise_machine       BOOLEAN      NOT NULL DEFAULT FALSE,
    nb_relances           INTEGER      NOT NULL DEFAULT 0 CHECK (nb_relances >= 0),
    motif                 TEXT,
    date_faite            TIMESTAMPTZ,
    -- ON DELETE SET NULL : les occurrences prévisionnelles sont effacées dès
    -- qu'une validation réelle les rend fausses. Elles forment une chaîne, et
    -- sans cela la suppression du premier maillon échouerait.
    id_occurrence_source  INTEGER      REFERENCES occurrence (id_occurrence)
                                       ON DELETE SET NULL,
    date_creation         TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT occurrence_fenetre_bornee CHECK (
        NOT isempty(fenetre)
        AND lower(fenetre) IS NOT NULL
        AND upper(fenetre) IS NOT NULL
    ),

    -- R10 : on ne place jamais une tâche hors de sa fenêtre d'échéance.
    CONSTRAINT occurrence_creneau_dans_fenetre
        CHECK (creneau IS NULL OR creneau <@ fenetre),

    -- R21 : une occurrence faite porte toujours sa date réelle d'exécution.
    -- Le contrôle « jamais dans le futur » est un trigger : now() n'est pas
    -- immutable et ne peut pas figurer dans un CHECK.
    CONSTRAINT occurrence_faite_datee
        CHECK (statut <> 'faite' OR date_faite IS NOT NULL),

    -- R11 : deux tâches à heure imposée ne se chevauchent pas. Les rappels
    -- d'une même journée, eux, cohabitent : sinon on ne pourrait pas faire
    -- l'aspirateur et la litière le même mardi.
    CONSTRAINT occurrence_sans_chevauchement
        EXCLUDE USING gist (id_utilisateur WITH =, creneau WITH &&)
        WHERE (creneau IS NOT NULL
               AND NOT rappel_journee
               AND statut IN ('planifiee', 'notifiee'))
);

CREATE INDEX occurrence_statut_idx  ON occurrence (statut);
CREATE INDEX occurrence_tache_idx   ON occurrence (id_tache, statut);
CREATE INDEX occurrence_fenetre_idx ON occurrence USING gist (fenetre);

COMMENT ON COLUMN occurrence.nb_relances IS
    'Nombre de reports d''office. Ne limite rien : une tâche revient jusqu''à
     ce qu''elle soit faite. Sert à afficher « en retard depuis 3 jours » et à
     repérer les tâches qu''on ne fait jamais (R26).';

COMMENT ON COLUMN occurrence.rappel_journee IS
    'Recopié de la tâche par trigger. Dénormalisation assumée : une contrainte
     d''exclusion ne sait pas lire une table liée.';

COMMENT ON COLUMN occurrence.motif IS
    'Raison du placement ou de l''échec. C''est ce qui rend le système
     compréhensible plutôt qu''arbitraire (R20).';


-- -----------------------------------------------------------------------------
-- Notification                                                     (R27, R28)
-- -----------------------------------------------------------------------------
CREATE TABLE notification (
    id_notification  SERIAL       PRIMARY KEY,
    id_utilisateur   INTEGER      NOT NULL REFERENCES utilisateur (id_utilisateur),
    id_occurrence    INTEGER      REFERENCES occurrence (id_occurrence),
    type             VARCHAR(30)  NOT NULL
                                  CHECK (type IN ('rappel', 'bilan', 'alerte')),
    contenu          TEXT         NOT NULL,
    statut           VARCHAR(20)  NOT NULL DEFAULT 'a_envoyer'
                                  CHECK (statut IN ('a_envoyer', 'envoyee', 'echec')),
    date_creation    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    date_envoi       TIMESTAMPTZ,

    CONSTRAINT notification_envoi_date
        CHECK (statut <> 'envoyee' OR date_envoi IS NOT NULL)
);

CREATE INDEX notification_a_envoyer_idx ON notification (statut) WHERE statut = 'a_envoyer';

COMMENT ON TABLE notification IS
    'Enregistrée d''abord, envoyée ensuite. Un échec d''envoi laisse la ligne
     en attente et ne la perd pas (R28).';


-- -----------------------------------------------------------------------------
-- Stock de vêtements de travail                              (R13, R14, R15)
-- -----------------------------------------------------------------------------
CREATE TABLE article_travail (
    id_article       SERIAL       PRIMARY KEY,
    code             VARCHAR(30)  NOT NULL UNIQUE,
    libelle          VARCHAR(100) NOT NULL,
    quantite_totale  INTEGER      NOT NULL CHECK (quantite_totale > 0),
    quantite_propre  INTEGER      NOT NULL CHECK (quantite_propre >= 0),
    seuil_securite   INTEGER      NOT NULL DEFAULT 1 CHECK (seuil_securite >= 0),
    jours_par_unite  INTEGER      NOT NULL DEFAULT 1 CHECK (jours_par_unite > 0),
    heures_sechage   INTEGER      NOT NULL DEFAULT 24 CHECK (heures_sechage > 0),
    disponible_le    TIMESTAMPTZ,
    date_maj         TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT article_propre_borne CHECK (quantite_propre <= quantite_totale),
    CONSTRAINT article_seuil_borne  CHECK (seuil_securite  <= quantite_totale)
);

COMMENT ON COLUMN article_travail.disponible_le IS
    'Un vêtement lavé n''est pas un vêtement portable. Tant que cette date
     n''est pas atteinte, les unités en séchage ne comptent pas dans le stock
     utilisable (R36).';

COMMENT ON COLUMN article_travail.quantite_propre IS
    'Maintenue par trigger à chaque mouvement, jamais écrite directement (R15).';

CREATE TABLE mouvement_stock (
    id_mouvement    SERIAL       PRIMARY KEY,
    id_article      INTEGER      NOT NULL REFERENCES article_travail (id_article),
    id_occurrence   INTEGER      REFERENCES occurrence (id_occurrence),
    type            VARCHAR(20)  NOT NULL
                                 CHECK (type IN ('salissure', 'lavage',
                                                 'retour_propre', 'recalage')),
    quantite        INTEGER      NOT NULL CHECK (quantite <> 0),
    date_mouvement  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX mouvement_article_idx ON mouvement_stock (id_article, date_mouvement DESC);

COMMENT ON TABLE mouvement_stock IS
    'Journal du stock. On peut toujours reconstituer pourquoi il ne restait
     qu''un t-shirt propre un mardi soir (R15).';
