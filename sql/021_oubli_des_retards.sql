-- rejouable : ALTER ... IF NOT EXISTS, UPDATE gardés, DROP puis CREATE.
-- =============================================================================
-- 021 : on oublie ce qu'on ne fera plus                            (EXE-12)
--
-- Le report d'office repoussait indéfiniment. Une tâche non faite revenait
-- chaque soir, un jour de retard de plus, sans fin. La liste s'allongeait, la
-- relance perdait son sens, et l'on finissait par ne plus rien lire.
--
-- Passé un délai propre à la tâche, on abandonne. Cinq jours pour une tâche
-- ordinaire : au-delà, elle ne se fera pas, et la semaine suivante en apportera
-- une autre. Trois jours pour une séance de sport : une séance manquée ne se
-- rattrape pas, elle se remplace par la suivante.
--
-- Le délai est une donnée de la tâche et non une constante du code, pour se
-- régler sans migration.
-- =============================================================================

ALTER TABLE tache ADD COLUMN IF NOT EXISTS abandon_apres_jours SMALLINT NOT NULL DEFAULT 5
      CHECK (abandon_apres_jours >= 0);

COMMENT ON COLUMN tache.abandon_apres_jours IS
    'Jours de retard au-delà desquels l''occurrence est abandonnée. 0 : jamais.';

-- Seulement les lignes restées à la valeur par défaut : un délai déjà réglé à
-- la main ne doit pas être remis à zéro par un rejeu.
UPDATE tache SET abandon_apres_jours = 3
 WHERE categorie = 'sport' AND abandon_apres_jours = 5;


-- -----------------------------------------------------------------------------
-- Report d'office, désormais borné                                      (EXE-12)
--
-- Le retard se lit dans `v_occurrence`, qui le calcule déjà : le plus grand du
-- nombre de reports et des jours écoulés depuis l'échéance. Le recopier ici
-- ferait deux définitions d'une même règle, et un jour elles divergeraient.
--
-- La valeur de retour passe de l'entier au JSONB : reporter, abandonner et
-- alerter sont trois issues, et n'en compter qu'une revenait à ne pas savoir
-- ce que la nuit avait fait.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS reporter_taches_du_jour();

CREATE FUNCTION reporter_taches_du_jour() RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    o             RECORD;
    v_reportees   INTEGER := 0;
    v_abandonnees INTEGER := 0;
    v_alertes     INTEGER := 0;
    v_demain      DATE := jour_de(now()) + 1;
BEGIN
    FOR o IN
        SELECT oc.id_occurrence, oc.id_utilisateur, oc.creneau, oc.fenetre,
               oc.rappel_journee,
               t.reportable, t.libelle, t.abandon_apres_jours,
               v.jours_de_retard
          FROM occurrence oc
          JOIN tache t        ON t.id_tache = oc.id_tache
          JOIN v_occurrence v ON v.id_occurrence = oc.id_occurrence
         WHERE oc.statut IN ('planifiee', 'notifiee')
           AND oc.creneau IS NOT NULL
           AND upper(oc.creneau) <= now()
    LOOP
        -- EXE-12 : passé le délai, on oublie. Un délai nul dit que la tâche ne
        -- s'abandonne jamais.
        IF o.abandon_apres_jours > 0 AND o.jours_de_retard >= o.abandon_apres_jours THEN
            UPDATE occurrence
               SET statut  = 'abandonnee',
                   creneau = NULL,
                   motif   = format('Oubliée après %s jour(s) de retard',
                                    o.jours_de_retard)
             WHERE id_occurrence = o.id_occurrence;

            INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
            VALUES (o.id_utilisateur, o.id_occurrence, 'alerte',
                    format('%s abandonnée : %s jour(s) de retard. La prochaine '
                           'occurrence suivra son cours.',
                           o.libelle, o.jours_de_retard));

            v_abandonnees := v_abandonnees + 1;
            CONTINUE;
        END IF;

        -- Une lessive de travail en retard ne se reporte pas : le report ne
        -- résout rien, il faut le savoir tout de suite. Le compteur avance
        -- quand même, sans quoi elle paraîtrait à l'heure et ne serait jamais
        -- abandonnée.
        IF NOT o.reportable THEN
            UPDATE occurrence
               SET nb_relances = nb_relances + 1
             WHERE id_occurrence = o.id_occurrence;

            INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
            VALUES (o.id_utilisateur, o.id_occurrence, 'alerte',
                    format('%s non faite et non reportable.', o.libelle));

            v_alertes := v_alertes + 1;
            CONTINUE;
        END IF;

        UPDATE occurrence
           SET creneau     = NULL,
               statut      = 'a_placer',
               nb_relances = nb_relances + 1,
               fenetre     = fenetre_pour(o.rappel_journee,
                                          lower(o.fenetre),
                                          GREATEST(upper(o.fenetre), debut_jour(v_demain + 1))),
               motif       = 'Reportée au lendemain, non faite'
         WHERE id_occurrence = o.id_occurrence;

        v_reportees := v_reportees + 1;
    END LOOP;

    RETURN jsonb_build_object('reportees',   v_reportees,
                              'abandonnees', v_abandonnees,
                              'alertes',     v_alertes);
END $$;

COMMENT ON FUNCTION reporter_taches_du_jour IS
    'Report d''office de minuit. Reporte, abandonne au-delà du délai de la
     tâche, ou alerte pour une tâche non reportable. Rend le compte des trois.';


-- -----------------------------------------------------------------------------
-- Solder les retards en cours                                           (EXE-12)
--
-- La règle ne vaut que pour l'avenir : les occurrences déjà en retard au moment
-- où on l'installe attendent minuit. Cette fonction les solde tout de suite, et
-- ne sert qu'une fois.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION solder_les_retards(p_jours_min SMALLINT DEFAULT 1)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_soldees INTEGER;
BEGIN
    WITH a_solder AS (
        SELECT v.id_occurrence, v.jours_de_retard
          FROM v_occurrence v
         WHERE v.en_retard
           AND v.statut IN ('a_placer', 'planifiee', 'notifiee')
           AND v.jours_de_retard >= p_jours_min
    )
    UPDATE occurrence oc
       SET statut  = 'abandonnee',
           creneau = NULL,
           motif   = format('Ardoise soldée : %s jour(s) de retard',
                            a.jours_de_retard)
      FROM a_solder a
     WHERE a.id_occurrence = oc.id_occurrence;

    GET DIAGNOSTICS v_soldees = ROW_COUNT;
    RETURN v_soldees;
END $$;

COMMENT ON FUNCTION solder_les_retards IS
    'Abandonne les occurrences déjà en retard. Sans notification : on solde une
     ardoise, on ne réclame rien.';
