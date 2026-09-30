-- NON rejouable : ce fichier efface des lignes. Le rejouer effacerait la
-- relecture qu'il vient de permettre.
-- =============================================================================
-- 042 : relire les billets des voyages à venir                        (BIL-12)
--
-- L'ancien lecteur ne comprenait pas le format actuel. Il en tirait le jour du
-- voyage sans l'heure, et gelait des journées approximatives : un voyage du 2
-- au 4 octobre devenait une absence du 3 au 6.
--
-- Corriger le lecteur ne suffit pas : ces courriels sont marqués comme vus, et
-- la relève ne les rouvrira jamais. On efface donc leur trace, ainsi que les
-- absences et les trains qu'ils avaient produits, pour les seuls voyages qui
-- n'ont pas encore eu lieu. Le passé reste tel qu'il a été vécu.
--
-- La prochaine relève — « /billets », ou celle de la nuit — les relira.
-- =============================================================================

DO $$
DECLARE
    c        RECORD;
    v_billets INTEGER := 0;
BEGIN
    FOR c IN
        SELECT co.id_courriel, co.id_absence
          FROM courriel co
          LEFT JOIN absence a ON a.id_absence = co.id_absence
         WHERE (co.id_absence IS NOT NULL AND upper(a.periode) > now())
            OR (co.id_absence IS NULL AND co.statut IN ('illisible', 'refuse'))
    LOOP
        IF c.id_absence IS NOT NULL THEN
            PERFORM oublier_trajet(c.id_absence);
        END IF;
        DELETE FROM courriel WHERE id_courriel = c.id_courriel;
        v_billets := v_billets + 1;
    END LOOP;

    RAISE NOTICE '% courriel(s) de billet à relire', v_billets;
END $$;

-- Les journées libérées retournent au ménage tout de suite, sans attendre la
-- nuit : le planning du bot serait faux entre-temps.
SELECT placer_taches();
