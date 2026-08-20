-- =============================================================================
-- 006 : assignations par défaut
--
-- Ce fichier ne fait rien tant que les comptes n'existent pas : les UPDATE
-- ne trouvent simplement aucune ligne. Il faut donc le rejouer après avoir
-- créé les utilisateurs, ce que fait `./sql/appliquer.sh` sans risque puisque
-- les instructions sont idempotentes.
--
-- La séparation est volontaire : les données de référence (005) décrivent des
-- règles publiables, les assignations dépendent de qui vit dans l'appartement.
-- =============================================================================

-- Le pliage du linge est assigné à Lorette.
UPDATE tache
   SET id_utilisateur_defaut = u.id_utilisateur
  FROM utilisateur u
 WHERE u.pseudo = 'lorette'
   AND tache.code = 'PLIER_LINGE';

-- Tout le reste revient à Thomas par défaut. Le grand nettoyage lui est
-- rattaché aussi : c'est lui qui portera la notification, même si la tâche
-- exige la présence des deux.
UPDATE tache
   SET id_utilisateur_defaut = u.id_utilisateur
  FROM utilisateur u
 WHERE u.pseudo = 'thomas'
   AND tache.id_utilisateur_defaut IS NULL;

-- Les emplois du temps collectés sont ceux de Thomas. Sans ce rattachement,
-- l'ordonnanceur ne saurait pas à qui affecter les cours qu'il ramène la nuit.
UPDATE source
   SET id_utilisateur = u.id_utilisateur
  FROM utilisateur u
 WHERE u.pseudo = 'thomas'
   AND source.id_utilisateur IS NULL;
