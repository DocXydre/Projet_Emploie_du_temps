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
