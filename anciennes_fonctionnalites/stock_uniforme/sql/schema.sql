-- =============================================================================
-- Stock d'uniforme : tables, vue et triggers, tels qu'en base avant la 031.
--
-- Extrait de la base après les migrations 001 à 029 (pg_dump), et non recopié
-- à la main : c'est l'état réel, colonnes ajoutées par la 014 comprises.
--
-- Les données de production n'ont pas été effacées : les deux tables vivent
-- dans le schéma « archive ». Pour les remettre en service :
--
--     ALTER TABLE archive.article_travail SET SCHEMA public;
--     ALTER TABLE archive.mouvement_stock SET SCHEMA public;
--
-- puis rejouer fonctions.sql, et recréer la vue et les triggers ci-dessous.
-- =============================================================================

--
--

--
--

CREATE TABLE article_travail (
    id_article integer NOT NULL,
    code character varying(30) NOT NULL,
    libelle character varying(100) NOT NULL,
    quantite_totale integer NOT NULL,
    quantite_propre integer NOT NULL,
    seuil_securite integer DEFAULT 1 NOT NULL,
    jours_par_unite integer DEFAULT 1 NOT NULL,
    heures_sechage integer DEFAULT 24 NOT NULL,
    disponible_le timestamp with time zone,
    date_maj timestamp with time zone DEFAULT now() NOT NULL,
    journees_portees smallint DEFAULT 0 NOT NULL,
    dernier_jour_compte date,
    CONSTRAINT article_propre_borne CHECK ((quantite_propre <= quantite_totale)),
    CONSTRAINT article_seuil_borne CHECK ((seuil_securite <= quantite_totale)),
    CONSTRAINT article_travail_heures_sechage_check CHECK ((heures_sechage > 0)),
    CONSTRAINT article_travail_journees_portees_check CHECK ((journees_portees >= 0)),
    CONSTRAINT article_travail_jours_par_unite_check CHECK ((jours_par_unite > 0)),
    CONSTRAINT article_travail_quantite_propre_check CHECK ((quantite_propre >= 0)),
    CONSTRAINT article_travail_quantite_totale_check CHECK ((quantite_totale > 0)),
    CONSTRAINT article_travail_seuil_securite_check CHECK ((seuil_securite >= 0))
);

--
--

CREATE SEQUENCE article_travail_id_article_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
--

ALTER SEQUENCE article_travail_id_article_seq OWNED BY article_travail.id_article;

--
--

CREATE TABLE mouvement_stock (
    id_mouvement integer NOT NULL,
    id_article integer NOT NULL,
    id_occurrence integer,
    type character varying(20) NOT NULL,
    quantite integer NOT NULL,
    date_mouvement timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mouvement_stock_quantite_check CHECK ((quantite <> 0)),
    CONSTRAINT mouvement_stock_type_check CHECK (((type)::text = ANY ((ARRAY['salissure'::character varying, 'lavage'::character varying, 'retour_propre'::character varying, 'recalage'::character varying])::text[])))
);

--
--

CREATE SEQUENCE mouvement_stock_id_mouvement_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
--

ALTER SEQUENCE mouvement_stock_id_mouvement_seq OWNED BY mouvement_stock.id_mouvement;

--
--

CREATE VIEW v_stock AS
 SELECT id_article,
    code,
    libelle,
    quantite_totale,
    quantite_propre,
    seuil_securite,
    jours_par_unite,
    heures_sechage,
    disponible_le,
        CASE
            WHEN ((disponible_le IS NULL) OR (disponible_le <= now())) THEN quantite_propre
            ELSE 0
        END AS quantite_utilisable,
    ((disponible_le IS NOT NULL) AND (disponible_le > now())) AS en_sechage,
        CASE
            WHEN ((disponible_le IS NOT NULL) AND (disponible_le > now())) THEN 0
            ELSE (quantite_propre * jours_par_unite)
        END AS jours_de_travail_couverts
   FROM article_travail a;

--
--

ALTER TABLE ONLY article_travail ALTER COLUMN id_article SET DEFAULT nextval('article_travail_id_article_seq'::regclass);

--
--

ALTER TABLE ONLY mouvement_stock ALTER COLUMN id_mouvement SET DEFAULT nextval('mouvement_stock_id_mouvement_seq'::regclass);

--
--

ALTER TABLE ONLY article_travail
    ADD CONSTRAINT article_travail_code_key UNIQUE (code);

--
--

ALTER TABLE ONLY article_travail
    ADD CONSTRAINT article_travail_pkey PRIMARY KEY (id_article);

--
--

ALTER TABLE ONLY mouvement_stock
    ADD CONSTRAINT mouvement_stock_pkey PRIMARY KEY (id_mouvement);

--
--

CREATE INDEX mouvement_article_idx ON mouvement_stock USING btree (id_article, date_mouvement DESC);

--
--

CREATE TRIGGER mouvement_appliquer AFTER INSERT ON mouvement_stock FOR EACH ROW EXECUTE FUNCTION trg_mouvement_appliquer();

--
--

CREATE TRIGGER mouvement_compteur AFTER INSERT ON mouvement_stock FOR EACH ROW EXECUTE FUNCTION trg_mouvement_compteur();

--
--

ALTER TABLE ONLY mouvement_stock
    ADD CONSTRAINT mouvement_stock_id_article_fkey FOREIGN KEY (id_article) REFERENCES article_travail(id_article);

--
--

ALTER TABLE ONLY mouvement_stock
    ADD CONSTRAINT mouvement_stock_id_occurrence_fkey FOREIGN KEY (id_occurrence) REFERENCES occurrence(id_occurrence) ON DELETE SET NULL;

--
--


-- -----------------------------------------------------------------------------
-- Colonne retirée de la table tache
-- -----------------------------------------------------------------------------
ALTER TABLE tache ADD COLUMN lave_uniforme BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE tache ADD CONSTRAINT tache_lavage_coherent
    CHECK (NOT lave_uniforme OR utilise_machine);
UPDATE tache SET lave_uniforme = TRUE, active = TRUE WHERE code = 'LESSIVE_TRAVAIL';

-- La tâche elle-même est restée en base, désactivée. Sa définition d'origine
-- (code, libellé, catégorie, priorité, durée, périodicité min et max, rappel,
-- heures, utilise_machine, lave_uniforme, reportable) :
--
--  ('LESSIVE_TRAVAIL', 'Lessive de travail',        'linge',     1,  15,  3, 14, FALSE, '21:45', '23:30', TRUE,  TRUE,  FALSE),


-- -----------------------------------------------------------------------------
-- Données de départ (005_donnees.sql)
-- -----------------------------------------------------------------------------
-- Articles de travail
--
-- Trois t-shirts, une unité couvre un jour de travail. Deux pantalons, une
-- unité couvre deux jours. Seuil de sécurité à 1 : on ne descend jamais à zéro.
-- Les durées de séchage seront à corriger après la première mauvaise surprise,
-- c'est précisément pour ça qu'elles sont en base et pas dans le code.
-- -----------------------------------------------------------------------------
INSERT INTO article_travail (code, libelle, quantite_totale, quantite_propre,
                             seuil_securite, jours_par_unite, heures_sechage) VALUES
    ('TSHIRT',   'T-shirt McDonald''s',  3, 3, 1, 1, 24),
    ('PANTALON', 'Pantalon McDonald''s', 2, 2, 1, 2, 36);
