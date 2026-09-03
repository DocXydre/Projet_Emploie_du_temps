-- rejouable : uniquement des CREATE OR REPLACE.
-- =============================================================================
-- 015 : ce que l'on déclare soi-même                        (UNI-15, EXE-11)
--
-- Trois gestes que le système ne pouvait pas enregistrer, et qui manquaient
-- après une semaine d'usage réel :
--
--   - dire combien de vêtements propres on a vraiment ;
--   - dire qu'une tâche a été faite alors qu'elle n'était pas prévue ce jour ;
--   - poser une occupation à la main depuis le bot.
--
-- Le point commun : le système suit ce qu'il a vu passer, et la réalité, elle,
-- avance sans lui. Il faut pouvoir la lui redire.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Recaler le stock d'un article                                        (UNI-15)
--
-- « J'ai deux t-shirts propres. » On calcule l'écart avec ce que la base croit,
-- et on l'écrit comme un mouvement de recalage : la quantité propre n'est
-- jamais modifiée directement, elle reste le résultat du journal (UNI-3).
--
-- Le compteur de journées portées repart de zéro, et la journée du jour est
-- marquée comme comptée : recaler après avoir sorti un pantalon de la machine
-- ne doit pas laisser le rattrapage de la nuit le salir une fois de plus.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recaler_uniforme(
    p_code   VARCHAR,
    p_propre INTEGER
) RETURNS TABLE (code VARCHAR, quantite_propre INTEGER, ecart INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    a      RECORD;
    v_ecart INTEGER;
BEGIN
    SELECT * INTO a FROM article_travail WHERE article_travail.code = p_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Article % inconnu', p_code USING ERRCODE = 'no_data_found';
    END IF;

    IF p_propre < 0 OR p_propre > a.quantite_totale THEN
        RAISE EXCEPTION 'Un stock propre de % est impossible : % en tout',
                        p_propre, a.quantite_totale
              USING ERRCODE = 'check_violation';
    END IF;

    v_ecart := p_propre - a.quantite_propre;

    -- La contrainte interdit une quantité nulle : rien à écrire si le compte
    -- était déjà bon.
    IF v_ecart <> 0 THEN
        INSERT INTO mouvement_stock (id_article, type, quantite)
        VALUES (a.id_article, 'recalage', v_ecart);
    END IF;

    UPDATE article_travail
       SET journees_portees    = 0,
           dernier_jour_compte = GREATEST(COALESCE(dernier_jour_compte, jour_de(now())),
                                          jour_de(now())),
           -- Ce qu'on déclare propre est portable tout de suite : on ne va pas
           -- attendre un séchage qui a déjà eu lieu.
           disponible_le       = CASE WHEN p_propre > 0 THEN NULL ELSE disponible_le END,
           date_maj            = now()
     WHERE id_article = a.id_article;

    RETURN QUERY
    SELECT v.code, v.quantite_propre, v_ecart
      FROM article_travail v WHERE v.id_article = a.id_article;
END $$;

COMMENT ON FUNCTION recaler_uniforme IS
    'Déclare le stock propre réel d''un article. Écrit l''écart au journal des
     mouvements et remet le compteur de journées portées à zéro (UNI-15).';


-- -----------------------------------------------------------------------------
-- Déclarer une tâche faite hors planning                               (EXE-11)
--
-- On a passé l'aspirateur un dimanche où il n'était pas prévu. La récurrence
-- doit en tenir compte : le prochain passage repart d'aujourd'hui.
--
-- Deux cas. Soit une occurrence ouverte existe pour cette tâche — on valide
-- celle-là, et toute la mécanique habituelle s'applique. Soit il n'y en a
-- aucune, et on en crée une, déjà datée, pour la valider dans la foulée : le
-- trigger de validation se charge du reste, régénération comprise.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION declarer_faite(
    p_utilisateur INTEGER,
    p_code_tache  VARCHAR,
    p_quand       TIMESTAMPTZ DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    t            RECORD;
    v_occurrence INTEGER;
    v_quand      TIMESTAMPTZ := COALESCE(p_quand, now());
BEGIN
    SELECT * INTO t FROM tache WHERE code = p_code_tache AND active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tâche % inconnue ou inactive', p_code_tache
              USING ERRCODE = 'no_data_found';
    END IF;

    IF v_quand > now() THEN
        RAISE EXCEPTION 'On ne déclare pas fait ce qui ne l''est pas encore'
              USING ERRCODE = 'check_violation';
    END IF;

    -- La plus proche d'abord : si deux occurrences traînent, c'est celle dont
    -- l'échéance approche que l'on vient de faire.
    SELECT id_occurrence INTO v_occurrence
      FROM occurrence
     WHERE id_tache = t.id_tache
       AND statut IN ('a_placer', 'planifiee', 'notifiee')
       AND (id_utilisateur IS NULL OR id_utilisateur = p_utilisateur)
     ORDER BY echeance_max
     LIMIT 1;

    IF v_occurrence IS NULL THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, echeance_min, echeance_max,
                                statut, origine, motif)
        VALUES (t.id_tache, p_utilisateur, v_quand, v_quand,
                'a_placer', 'manuelle', 'Déclarée faite hors planning')
        RETURNING id_occurrence INTO v_occurrence;
    ELSE
        -- L'occurrence pouvait être assignée à l'autre : celui qui l'a faite
        -- est celui qui la valide.
        UPDATE occurrence SET id_utilisateur = p_utilisateur
         WHERE id_occurrence = v_occurrence AND id_utilisateur IS NULL;
    END IF;

    PERFORM valider_occurrence(v_occurrence, p_utilisateur, v_quand);
    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION declarer_faite IS
    'Valide une tâche faite spontanément. Reprend l''occurrence ouverte s''il y
     en a une, en crée une sinon. La récurrence repart de la date déclarée
     (EXE-11).';


-- -----------------------------------------------------------------------------
-- Poser une occupation à la main                                       (COL-13)
--
-- La saisie manuelle existait déjà par l'API. Cette fonction la rend appelable
-- avec ce dont on dispose depuis un téléphone : un titre, un jour, deux heures.
-- Elle ne fait pas le placement — l'appelant s'en charge, une seule fois.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ajouter_occupation(
    p_utilisateur INTEGER,
    p_libelle     VARCHAR,
    p_debut       TIMESTAMPTZ,
    p_fin         TIMESTAMPTZ,
    -- « autre » par défaut : c'est le type qui échappe à la contrainte de
    -- non-chevauchement, réservée aux cours et aux shifts. Un rendez-vous
    -- pendant un cours doit pouvoir être saisi, quitte à être bizarre — et il
    -- occupe l'agenda de la même façon pour le placement des tâches.
    p_type        VARCHAR DEFAULT 'autre',
    p_lieu        VARCHAR DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_source     INTEGER;
    v_occupation INTEGER;
BEGIN
    IF p_fin <= p_debut THEN
        RAISE EXCEPTION 'La fin doit venir après le début'
              USING ERRCODE = 'check_violation';
    END IF;

    SELECT id_source INTO v_source FROM source WHERE code = 'MANUELLE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source MANUELLE absente' USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO occupation (id_utilisateur, id_source, type, libelle, lieu, periode)
    VALUES (p_utilisateur, v_source, p_type, p_libelle, p_lieu,
            tstzrange(p_debut, p_fin, '[)'))
    RETURNING id_occupation INTO v_occupation;

    RETURN v_occupation;
END $$;

COMMENT ON FUNCTION ajouter_occupation IS
    'Crée une occupation saisie à la main. La contrainte d''exclusion refuse un
     chevauchement avec une occupation existante du même utilisateur (COL-13).';
