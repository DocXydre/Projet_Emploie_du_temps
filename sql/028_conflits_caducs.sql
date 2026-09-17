-- rejouable : ALTER ... IF EXISTS / IF NOT EXISTS, DROP puis CREATE, et un
-- UPDATE qui ne touche que ce qui reste en attente.
-- -----------------------------------------------------------------------------
-- 028 — Les conflits qui n'ont plus lieu d'être                (COL-19, COL-20)
--
-- Un conflit naît d'un chevauchement constaté à un instant donné. Rien ne le
-- refermait ensuite : il restait « en_attente » pour toujours, et le bot le
-- reproposait à chaque /conflits. Deux cas se voyaient tout de suite.
--
--   1. Le conflit est passé. Arbitrer un cours d'il y a trois semaines ne sert
--      plus à rien : la journée a eu lieu, quel que soit le choix. La vue le
--      proposait pourtant, parce que `a_arbitrer` ne bornait que le futur.
--
--   2. Le conflit a été tranché autrement qu'en répondant à la question. Choisir
--      un groupe de TD, ou écarter l'UE au choix qu'on ne suit pas, fait
--      disparaître la séance rejetée du flux filtré : le chevauchement n'existe
--      plus. La ligne de conflit, elle, restait.
--
-- On ne supprime pas ces lignes : l'historique des collectes doit rester
-- lisible. On les marque « caduc », avec le motif, et la vue cesse de les
-- proposer.
-- -----------------------------------------------------------------------------

ALTER TABLE conflit ADD COLUMN IF NOT EXISTS motif_caducite VARCHAR(30);

COMMENT ON COLUMN conflit.motif_caducite IS
    'passe : la période est derrière nous. sans_objet : la séance rejetée
     n''est plus proposée par la source, filtrée ou corrigée à l''origine.';

ALTER TABLE conflit DROP CONSTRAINT IF EXISTS conflit_statut_check;
ALTER TABLE conflit ADD CONSTRAINT conflit_statut_check
    CHECK (statut IN ('en_attente', 'resolu', 'caduc'));

-- « resolu » garde son sens : quelqu'un a choisi. « caduc » dit que la question
-- ne se pose plus, et porte donc un motif au lieu d'un choix.
ALTER TABLE conflit DROP CONSTRAINT IF EXISTS conflit_resolution_coherente;
ALTER TABLE conflit ADD CONSTRAINT conflit_resolution_coherente CHECK (
       statut = 'en_attente'
    OR (statut = 'resolu' AND choix IS NOT NULL AND date_resolution IS NOT NULL)
    OR (statut = 'caduc'  AND motif_caducite IS NOT NULL AND date_resolution IS NOT NULL)
);


-- -----------------------------------------------------------------------------
-- COL-19 : on n'arbitre que le futur.
-- -----------------------------------------------------------------------------
-- Recréée plutôt que remplacée : `CREATE OR REPLACE` n'ajoute une colonne qu'en
-- dernière position, et `motif_caducite` se lit à côté de `statut`.
DROP VIEW IF EXISTS v_conflit;

CREATE VIEW v_conflit AS
SELECT
    c.id_conflit,
    c.statut,
    c.choix,
    c.motif_caducite,
    c.date_detection,
    s.code                        AS source,

    -- Ce qui est déjà au planning.
    o.id_occupation,
    o.libelle                     AS libelle_existante,
    lower(o.periode)              AS debut_existante,
    upper(o.periode)              AS fin_existante,
    o.lieu                        AS lieu_existante,

    -- Ce que la source voudrait mettre à la place.
    c.libelle                     AS libelle_nouvelle,
    lower(c.periode)              AS debut_nouvelle,
    upper(c.periode)              AS fin_nouvelle,
    c.lieu                        AS lieu_nouvelle,
    c.details                     AS details_nouvelle,

    -- COL-11 : au-delà de deux semaines, on ne dérange pas. L'emploi du temps a
    -- toutes les chances d'être corrigé d'ici là.
    -- COL-19 : en deçà de maintenant, il n'y a plus rien à décider.
    (    lower(c.periode) >  now()
     AND lower(c.periode) <= now() + INTERVAL '14 days') AS a_arbitrer,
    EXTRACT(DAY FROM lower(c.periode) - now())::INTEGER AS dans_combien_de_jours
FROM conflit c
JOIN occupation o ON o.id_occupation = c.id_occupation
JOIN source s     ON s.id_source = c.id_source;

COMMENT ON VIEW v_conflit IS
    'Les deux versions côte à côte, pour que le bot puisse poser la question
     sans que le client ait à recalculer quoi que ce soit. Seul un conflit à
     venir, et à moins de deux semaines, est à arbitrer.';


-- -----------------------------------------------------------------------------
-- Périmer ce qui est derrière nous.                                    (COL-19)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION perimer_les_conflits() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_nombre INTEGER;
BEGIN
    UPDATE conflit
       SET statut          = 'caduc',
           motif_caducite  = 'passe',
           date_resolution = now()
     WHERE statut = 'en_attente'
       AND lower(periode) <= now();

    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION perimer_les_conflits IS
    'Ferme les conflits dont la période a commencé : la question ne se pose
     plus, et une liste qui grossit sans fin ne se lit pas.';


-- -----------------------------------------------------------------------------
-- Périmer ce que la source ne propose plus.                            (COL-20)
--
-- Appelée en fin de collecte avec les clés des séances qui se sont réellement
-- heurtées à une occupation existante. Toute autre question en attente pour
-- cette source n'a plus d'objet : la séance a été filtrée (groupe de TD, UE
-- écartée), retirée du flux, ou elle ne chevauche plus rien.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION perimer_les_conflits_absents(
    p_source INTEGER,
    p_cles   TEXT[]
) RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_nombre INTEGER;
BEGIN
    UPDATE conflit
       SET statut          = 'caduc',
           motif_caducite  = 'sans_objet',
           date_resolution = now()
     WHERE id_source = p_source
       AND statut    = 'en_attente'
       AND lower(periode) > now()
       -- Un conflit ne s'enregistre qu'à moins de deux semaines (COL-11) :
       -- au-delà, l'absence de la clé ne prouve rien, la collecte peut
       -- simplement n'être pas allée jusque-là.
       AND lower(periode) <= now() + INTERVAL '14 days'
       AND NOT (cle_externe = ANY(COALESCE(p_cles, ARRAY[]::TEXT[])));

    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION perimer_les_conflits_absents IS
    'Ferme les conflits qu''une collecte ne reproduit plus : choisir un groupe
     ou écarter une UE règle le conflit aussi sûrement qu''un arbitrage.';


-- -----------------------------------------------------------------------------
-- Solde de l'existant : les conflits passés qui traînent depuis des semaines.
-- -----------------------------------------------------------------------------
SELECT perimer_les_conflits();
