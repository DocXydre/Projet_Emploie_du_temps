CREATE VIEW v_sante_fraicheur AS
SELECT u.id_utilisateur,
       GREATEST((SELECT max(sj.recue_le) FROM sante_jour sj
                  WHERE sj.id_utilisateur = u.id_utilisateur),
                (SELECT max(a.recue_le) FROM activite_sante a
                  WHERE a.id_utilisateur = u.id_utilisateur)) AS dernier_envoi,
       (SELECT max(sj.jour) FROM sante_jour sj
         WHERE sj.id_utilisateur = u.id_utilisateur)          AS dernier_jour
  FROM utilisateur u
 WHERE u.actif;

COMMENT ON VIEW v_sante_fraicheur IS
    'SAN-6 : la date du dernier envoi de l''application, par compte, pour que
     le coach dise quand ses données sont vieilles.';
