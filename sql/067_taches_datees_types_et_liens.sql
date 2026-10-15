-- =============================================================================
-- 067 : les tâches datées, les types de tâches, les liens       (TAC-20 à TAC-28)
--
-- Rejouable.
--
-- Trois choses qui ne se faisaient qu'à la main, dans la base :
--
--   une tâche pour aujourd'hui, entre deux dates, à une heure ou dans une plage,
--   et qu'on oublie si elle n'est pas faite                  TAC-22 à TAC-24
--   des types de tâches que le foyer nomme et colore         TAC-25, TAC-26
--   les liens entre tâches, posés depuis l'appli             TAC-27, TAC-28
--
-- Les liens n'ont pas de table nouvelle : ce sont les enchaînements, les
-- accompagnements et les remplacements qui existaient déjà (001, 049).
--
-- Aucune fonction ici : elles sont dans sql/definitions/.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Les types de tâches                                               (TAC-25)
--
-- La colonne `categorie` reste : le sport, le chat, la machine la lisent, et
-- avec eux une trentaine de fonctions. Le type est ce que l'utilisateur voit et
-- règle ; la famille technique suit le type, sans qu'il ait à la connaître.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS type_tache (
    id_type_tache SERIAL       PRIMARY KEY,
    libelle       VARCHAR(40)  NOT NULL,
    -- Libre : le sélecteur de couleur d'iOS rend n'importe quelle teinte.
    couleur       VARCHAR(7)   NOT NULL,
    -- Un nom de symbole SF, « pawprint ». L'appli le dessine, la base le garde.
    icone         VARCHAR(60)  NOT NULL DEFAULT 'checklist',
    duree_minutes SMALLINT     NOT NULL DEFAULT 15,
    priorite      SMALLINT     NOT NULL DEFAULT 4,
    categorie     VARCHAR(20)  NOT NULL DEFAULT 'menage',
    ordre         SMALLINT     NOT NULL DEFAULT 0,
    date_creation TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT type_tache_libelle_non_vide
        CHECK (length(btrim(libelle)) BETWEEN 1 AND 40),
    CONSTRAINT type_tache_couleur_hexa
        CHECK (couleur ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT type_tache_duree_raisonnable
        CHECK (duree_minutes BETWEEN 1 AND 480),
    CONSTRAINT type_tache_priorite_bornee
        CHECK (priorite BETWEEN 1 AND 5),
    -- Le sport n'est pas un type : il a son onglet et ses règles.
    CONSTRAINT type_tache_categorie_connue
        CHECK (categorie IN ('menage', 'linge', 'vaisselle', 'animal', 'admin'))
);

-- La casse ici ; les accents, `creer_type_tache()` les compare, un index ne
-- sachant pas appeler une fonction qui n'est pas immuable.
CREATE UNIQUE INDEX IF NOT EXISTS type_tache_libelle_unique
    ON type_tache (lower(btrim(libelle)));

COMMENT ON TABLE type_tache IS
    'TAC-25 : les types de tâches du foyer. Nom, couleur, icône, et ce qu''une
     tâche nouvelle de ce type prend par défaut.';
COMMENT ON COLUMN type_tache.categorie IS
    'TAC-25 : la famille technique que le type donne à ses tâches. Celle
     d''origine pour les cinq types de départ, « menage » pour les autres.';

-- Les cinq familles d'origine deviennent des types. Les couleurs sont celles
-- de l'appli (C.4) ; la vaisselle, qui partageait celle du ménage, a la sienne.
INSERT INTO type_tache (libelle, couleur, icone, duree_minutes, priorite, categorie, ordre)
SELECT v.libelle, v.couleur, v.icone, v.duree, v.priorite, v.categorie, v.ordre
  FROM (VALUES ('Ménage',        '#FFD166', 'house',      10, 4, 'menage',    1),
               ('Linge',         '#B794F6', 'tshirt',     15, 2, 'linge',     2),
               ('Vaisselle',     '#6FD3F2', 'fork.knife',  5, 2, 'vaisselle', 3),
               ('Chat',          '#FF9BCB', 'pawprint',    5, 1, 'animal',    4),
               ('Administratif', '#AEB8C8', 'doc.text',   15, 2, 'admin',     5)
       ) AS v(libelle, couleur, icone, duree, priorite, categorie, ordre)
 WHERE NOT EXISTS (SELECT 1 FROM type_tache t WHERE t.categorie = v.categorie
                                                AND t.ordre = v.ordre);


-- -----------------------------------------------------------------------------
-- 2. Le type d'une tâche                                               (TAC-25)
-- -----------------------------------------------------------------------------
ALTER TABLE tache ADD COLUMN IF NOT EXISTS id_type_tache INTEGER
    REFERENCES type_tache(id_type_tache) ON DELETE SET NULL;

UPDATE tache t
   SET id_type_tache = (SELECT y.id_type_tache FROM type_tache y
                         WHERE y.categorie = t.categorie
                         ORDER BY y.ordre, y.id_type_tache LIMIT 1)
 WHERE t.id_type_tache IS NULL
   AND t.categorie <> 'sport';

-- Toute tâche active hors sport a un type ; un sport n'en a jamais. Une tâche
-- arrêtée peut l'avoir perdu : supprimer un type vide ne touche pas l'histoire.
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_type_hors_sport;
ALTER TABLE tache ADD CONSTRAINT tache_type_hors_sport CHECK (
    CASE WHEN categorie = 'sport' THEN id_type_tache IS NULL
         ELSE id_type_tache IS NOT NULL OR NOT active END
);

CREATE INDEX IF NOT EXISTS tache_par_type ON tache (id_type_tache);

COMMENT ON COLUMN tache.id_type_tache IS
    'TAC-25 : le type affiché, son nom, sa couleur et son icône. Vide pour un
     sport, et pour une tâche arrêtée dont le type a été supprimé.';


-- -----------------------------------------------------------------------------
-- 3. Ce que devient une tâche ponctuelle pas faite                     (TAC-24)
-- -----------------------------------------------------------------------------
ALTER TABLE tache ADD COLUMN IF NOT EXISTS si_pas_faite VARCHAR(8)
    NOT NULL DEFAULT 'reporter';
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_si_pas_faite_connu;
ALTER TABLE tache ADD CONSTRAINT tache_si_pas_faite_connu
    CHECK (si_pas_faite IN ('reporter', 'oublier'));

COMMENT ON COLUMN tache.si_pas_faite IS
    'TAC-24 : « reporter », elle revient en retard jusqu''à être faite ;
     « oublier », le report de minuit qui suit sa dernière date l''abandonne.';


-- -----------------------------------------------------------------------------
-- 4. Une plage horaire contient la durée                               (TAC-23)
--
-- « À 18h30 » s'écrit avec une plage de la longueur exacte de la tâche : le
-- placement la pose alors à cette heure, ou nulle part. Une plage plus courte
-- que la tâche ne trouverait jamais de place, sans que rien le dise.
-- -----------------------------------------------------------------------------
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_plage_contient_la_duree;
ALTER TABLE tache ADD CONSTRAINT tache_plage_contient_la_duree CHECK (
    rappel_journee
    OR heure_max - heure_min >= make_interval(mins => duree_minutes)
);
