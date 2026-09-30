-- NON rejouable : ce fichier efface des lignes. Le rejouer effacerait la
-- relecture qu'il vient de permettre.
-- =============================================================================
-- 043 : relire vraiment les billets                          (BIL-16, BIL-17)
--
-- La 042 n'avait pas suffi. Elle ne rouvrait que les courriels rattachés à une
-- absence encore à venir, ou restés illisibles. Or un courriel de retour classé
-- « traité » sans avoir eu d'absence à fermer, ou dont l'absence avait été
-- annulée depuis, n'a ni l'un ni l'autre : il restait marqué comme vu. Son
-- aller était relu, lui non, et le voyage restait ouvert jusqu'à la prochaine
-- obligation au lieu de se fermer sur le train du retour.
--
-- On efface donc toute la mémoire des courriels récents. Ce qui est passé sera
-- relu puis classé sans rien déclarer (BIL-17) ; ce qui est à venir sera
-- reconstruit, avec les horaires cette fois.
-- =============================================================================

DO $$
DECLARE
    v_absence INTEGER;
    v_billets INTEGER;
    v_rendus  INTEGER := 0;
BEGIN
    -- 1. Les absences encore vivantes nées d'un billet s'en vont avec leurs
    --    trains. Elles seront recréées à la bonne heure.
    FOR v_absence IN
        SELECT DISTINCT c.id_absence
          FROM courriel c
          JOIN absence a ON a.id_absence = c.id_absence
         WHERE upper(a.periode) > now()
    LOOP
        PERFORM oublier_trajet(v_absence);
        v_rendus := v_rendus + 1;
    END LOOP;

    -- 2. Puis la trace des courriels récents, quel que soit leur sort. Au-delà
    --    de quatre mois, la relève ne les redemandera pas de toute façon.
    DELETE FROM courriel
     WHERE recu_le IS NULL OR recu_le > now() - INTERVAL '120 days';
    GET DIAGNOSTICS v_billets = ROW_COUNT;

    RAISE NOTICE '% absence(s) rendue(s), % courriel(s) à relire',
                 v_rendus, v_billets;
END $$;

-- Les journées libérées retournent au ménage tout de suite : le planning du bot
-- serait faux jusqu'à la nuit.
SELECT placer_taches();
