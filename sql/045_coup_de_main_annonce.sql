-- rejouable : ce fichier ne contient que des CREATE OR REPLACE.
-- =============================================================================
-- 045 : le coup de main se dit, et rééquilibre               (EXE-16, PLA-13)
--
-- Depuis la 036, faire une tâche prévue pour l'autre la lui retire et la
-- crédite à celui qui l'a faite. Il manquait deux choses, et ce sont les deux
-- qui comptent au quotidien.
--
-- D'abord le dire. Sans message, l'autre découvre la disparition de sa tâche
-- sans savoir si elle a été faite ou si le système a bougé tout seul. Le
-- rappel qui attendait encore dans la file part avec, puisqu'il n'a plus
-- d'objet.
--
-- Ensuite rééquilibrer. Reprendre une tâche à quelqu'un décale la balance de
-- la semaine, et le gel de sept jours empêchait justement le placement d'en
-- tenir compte. On libère donc ce qui n'a pas encore été annoncé, et la
-- répartition se refait avec les charges à jour : l'un a fait une tâche de
-- plus, l'autre en reprendra une.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Rouvrir la semaine à la répartition                               (PLA-13)
--
-- Ce qui est épinglé, annoncé, déjà commencé ou nominatif ne bouge pas. Le
-- reste repasse « à placer » et sera redistribué au prochain placement, qui
-- suit immédiatement.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reequilibrer(p_jours INTEGER DEFAULT 7)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_liberees INTEGER;
BEGIN
    UPDATE occurrence o
       SET id_utilisateur = NULL,
           creneau        = NULL,
           statut         = 'a_placer',
           motif          = NULL
      FROM tache t
     WHERE t.id_tache = o.id_tache
       AND o.statut = 'planifiee'
       AND NOT o.epinglee
       -- Une séance de sport est personnelle : elle ne se redistribue pas.
       AND o.origine <> 'quota'
       AND t.categorie <> 'sport'
       -- ABS-2 : le pliage du linge reste à Lorette, quoi qu'il arrive.
       AND t.id_utilisateur_defaut IS NULL
       -- TAC-9 : une tâche à deux n'a personne à qui la reprendre.
       AND NOT t.requiert_les_deux
       AND o.creneau IS NOT NULL
       AND lower(o.creneau) > now()
       AND lower(o.creneau) < now() + make_interval(days => p_jours)
       -- Une tâche déjà annoncée reste où elle est : on ne retire pas de la
       -- liste de quelqu'un ce qu'il a lu ce matin.
       AND NOT EXISTS (SELECT 1 FROM notification n
                        WHERE n.id_occurrence = o.id_occurrence
                          AND n.statut IN ('a_envoyer', 'envoyee'));

    GET DIAGNOSTICS v_liberees = ROW_COUNT;
    RETURN v_liberees;
END $$;

COMMENT ON FUNCTION reequilibrer IS
    'Libère l''assigné des tâches à venir non annoncées, pour que le placement
     suivant les redistribue avec les charges à jour (PLA-13).';


-- -----------------------------------------------------------------------------
-- 2. Valider, prévenir, rééquilibrer                           (EXE-14, EXE-16)
--
-- Corps repris de la migration 036, avec la suite qui manquait.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION valider_occurrence(
    p_occurrence  INTEGER,
    p_acteur      INTEGER,
    p_date_reelle TIMESTAMPTZ DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o        RECORD;
    v_ancien INTEGER;
BEGIN
    SELECT * INTO o FROM occurrence WHERE id_occurrence = p_occurrence FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Occurrence % introuvable', p_occurrence
              USING ERRCODE = 'no_data_found';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM utilisateur
                    WHERE id_utilisateur = p_acteur AND actif) THEN
        RAISE EXCEPTION 'Compte % inconnu ou désactivé', p_acteur
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    v_ancien := o.id_utilisateur;

    UPDATE occurrence
       SET statut         = 'faite',
           id_utilisateur = p_acteur,
           date_faite     = COALESCE(p_date_reelle, now())
     WHERE id_occurrence = p_occurrence;

    -- Un rappel qui n'est pas encore parti n'a plus d'objet : la tâche est
    -- faite. Le laisser partirait demander à quelqu'un de faire ce qui l'est.
    DELETE FROM notification
     WHERE id_occurrence = p_occurrence AND statut = 'a_envoyer';

    -- EXE-16 : la tâche quitte la liste de l'autre, il faut qu'il l'apprenne
    -- autrement qu'en constatant un trou.
    IF v_ancien IS NOT NULL AND v_ancien <> p_acteur THEN
        INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
        SELECT v_ancien, p_occurrence, 'alerte',
               format('👍 %s a fait « %s » à ta place. Elle quitte ta liste, '
                      || 'et je rééquilibre la suite de la semaine.',
                      (SELECT nom FROM utilisateur WHERE id_utilisateur = p_acteur),
                      (SELECT libelle FROM tache WHERE id_tache = o.id_tache));

        -- PLA-13 : la balance a bougé, la répartition doit suivre.
        PERFORM reequilibrer();
    END IF;

    RETURN p_occurrence;
END $$;

COMMENT ON FUNCTION valider_occurrence IS
    'Marque une occurrence faite et la crédite à celui qui la valide, même
     prévue pour l''autre (EXE-14). Le prévient (EXE-16) et rouvre la semaine
     à la répartition (PLA-13).';
