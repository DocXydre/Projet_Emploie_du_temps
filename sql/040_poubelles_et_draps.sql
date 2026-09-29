-- rejouable : INSERT ... ON CONFLICT DO NOTHING. Un rejeu n'écrase pas une
-- durée ou une périodicité corrigée en base depuis.
-- -----------------------------------------------------------------------------
-- 040 : sortir les poubelles, changer les draps                        (TAC-11)
--
-- Deux tâches qui manquaient, et qui ne se ressemblent en rien.
--
-- Les poubelles tous les quatre jours : courte, sans heure, mais qui ne se
-- reporte pas indéfiniment. Un sac oublié quatre jours de plus se sent.
--
-- Les draps toutes les deux semaines : longue, moins pressante, et reportable.
-- La décaler d'un jour ou deux ne coûte rien, et la semaine chargée où elle
-- tombe en a parfois besoin.
--
-- Aucune des deux n'a d'assigné : c'est le roulement qui décide, selon qui est
-- là et qui l'a faite la dernière fois (PLA-12).
-- -----------------------------------------------------------------------------

INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                   periodicite_min_jours, periodicite_max_jours,
                   rappel_journee, reportable)
VALUES
    ('POUBELLES', 'Sortir les poubelles',   'menage', 2,  5,  4,  4, TRUE, FALSE),
    ('DRAPS',     'Changer les draps',      'menage', 3, 20, 14, 16, TRUE, TRUE)
ON CONFLICT (code) DO NOTHING;
