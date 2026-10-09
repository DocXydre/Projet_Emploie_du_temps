-- =============================================================================
-- 056 : la mémoire du coach, en quatre étages              (MEM-1 à MEM-9)
--
-- Rejouable.
--
-- Le coach ne retient rien d'un appel à l'autre. Ce qu'il sait de l'histoire
-- de l'utilisateur lui est renvoyé à chaque appel, du plus résumé au plus
-- précis :
--
--   globale       tout ce qui précède les trois derniers mois, très résumé
--   archive_mois  le résumé d'un mois fini. Les trois derniers forment la
--                 mémoire « trois mois », les plus vieux sont versés dans la
--                 mémoire globale
--   mois          le mois en cours, nourri par les semaines finies
--   semaine       la semaine en cours, tenue par le coach chaque soir
--
-- et, en dessous, les dix derniers échanges mot pour mot.
--
-- Chaque écriture ajoute une version : rien ne s'écrase, un mauvais résumé se
-- défait. La version en vigueur est la dernière de son étage et de sa période.
--
-- Le carnet (note_coach) est remplacé par la mémoire globale. Ses notes y sont
-- recopiées une fois ; la table reste, avec ses lignes, pour l'historique.
-- =============================================================================

CREATE TABLE IF NOT EXISTS memoire_coach (
    id_memoire     BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur ON DELETE CASCADE,
    niveau         VARCHAR(12) NOT NULL
        CHECK (niveau IN ('globale', 'archive_mois', 'mois', 'semaine')),
    -- Le lundi de la semaine, le 1er du mois. Vide pour la mémoire globale.
    periode        DATE,
    texte          TEXT        NOT NULL,
    -- MEM-4 : qui a écrit cette version.
    auteur         VARCHAR(12) NOT NULL
        CHECK (auteur IN ('coach', 'utilisateur', 'resume', 'reprise')),
    -- MEM-6 : jusqu'où l'étage a déjà absorbé l'étage du dessous. Pour un mois,
    -- le lundi de la dernière semaine versée ; pour la globale, le 1er du
    -- dernier mois versé. Le roulement se rejoue sans rien verser deux fois.
    couvre_jusqu_au DATE,
    quand          TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Ce qu'a coûté un résumé, quand c'en est un.
    modele         VARCHAR(60),
    tokens_entree  INTEGER,
    tokens_sortie  INTEGER,
    CONSTRAINT memoire_periode CHECK ((niveau = 'globale') = (periode IS NULL)),
    CONSTRAINT memoire_semaine_lundi
        CHECK (niveau <> 'semaine' OR extract(isodow FROM periode) = 1),
    CONSTRAINT memoire_mois_premier
        CHECK (niveau NOT IN ('mois', 'archive_mois') OR extract(day FROM periode) = 1)
);
CREATE INDEX IF NOT EXISTS memoire_coach_en_vigueur
    ON memoire_coach (id_utilisateur, niveau, periode, id_memoire DESC);

-- MEM-8 : l'importance d'un échange, de 1 (courant) à 3 (à ne jamais perdre).
-- Elle se calcule en base à partir de ce que l'appel a réellement écrit.
ALTER TABLE echange
    ADD COLUMN IF NOT EXISTS importance SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_importance;
ALTER TABLE echange ADD CONSTRAINT echange_importance CHECK (importance BETWEEN 1 AND 3);
CREATE INDEX IF NOT EXISTS echange_par_importance
    ON echange (id_utilisateur, importance, quand);

-- DOS-2 : les paquets du dossier joints à l'appel, pour savoir après coup ce
-- que le coach avait sous les yeux.
ALTER TABLE appel_coach ADD COLUMN IF NOT EXISTS paquets TEXT[];

-- Le carnet est remplacé : ses outils disparaissent.
DROP FUNCTION IF EXISTS noter(INTEGER, VARCHAR, TEXT, VARCHAR, BOOLEAN);
DROP FUNCTION IF EXISTS oublier(INTEGER, INTEGER);

-- MEM-9 : les notes du carnet deviennent la première mémoire globale. Une
-- seule fois par compte : un compte qui a déjà une mémoire globale est laissé.
INSERT INTO memoire_coach (id_utilisateur, niveau, periode, texte, auteur)
SELECT n.id_utilisateur, 'globale', NULL,
       '## Ce que l''utilisateur a dit' || E'\n'
       || COALESCE(string_agg('- ' || n.texte, E'\n' ORDER BY n.categorie, n.id_note)
                       FILTER (WHERE n.source = 'utilisateur'), '- (rien)')
       || E'\n\n## Ce que j''ai déduit'  || E'\n'
       || COALESCE(string_agg('- ' || n.texte
                              || CASE WHEN n.confirmee THEN ' (confirmé)'
                                      ELSE ' (à confirmer)' END,
                              E'\n' ORDER BY n.categorie, n.id_note)
                       FILTER (WHERE n.source = 'deduction'), '- (rien)'),
       'reprise'
  FROM note_coach n
 WHERE NOT EXISTS (SELECT 1 FROM memoire_coach m
                    WHERE m.id_utilisateur = n.id_utilisateur AND m.niveau = 'globale')
 GROUP BY n.id_utilisateur;
