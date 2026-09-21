-- 034 : le sport repart de zéro. Une seule fois, au déploiement.
-- -----------------------------------------------------------------------------
-- Toutes les séances encore ouvertes s'effacent, choisies comme à déterminer,
-- et avec elles les choix qui nourrissaient les habitudes : les propositions
-- recommencent sans rien savoir.
--
-- L'historique reste : une séance faite ou abandonnée ne bouge pas.
--
-- Juste après, les trois semaines retrouvent leurs trois séances à déterminer
-- (SPT-23), sur les meilleurs créneaux du moment.
-- -----------------------------------------------------------------------------

BEGIN;

-- Les habitudes d'abord : elles tiennent aux séances par clé étrangère.
DELETE FROM choix_sport;

-- Ce qui n'est pas encore parti vers Telegram ne parlerait plus de rien.
DELETE FROM notification n
 WHERE n.statut = 'a_envoyer'
   AND (n.type = 'sport'
        OR n.id_occurrence IN (SELECT o.id_occurrence
                                 FROM occurrence o
                                 JOIN tache t ON t.id_tache = o.id_tache
                                WHERE t.code = 'SPORT'
                                  AND o.statut IN ('a_placer', 'planifiee', 'notifiee')));

DELETE FROM occurrence o
 USING tache t
 WHERE t.id_tache = o.id_tache
   AND t.code = 'SPORT'
   AND o.statut IN ('a_placer', 'planifiee', 'notifiee');

SELECT organiser_sport();

COMMIT;
